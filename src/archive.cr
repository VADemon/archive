# "Annotation Archive" (which provides scripts for archiving YouTube annotations)
# Copyright (C) 2018  Omar Roth
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "awscr-s3"
require "json"
require "kemal"
require "pg"
require "yaml"
require "./archive/*"

class Config
  YAML.mapping({
    db: NamedTuple(
      user: String,
      password: String,
      host: String,
      port: Int32,
      dbname: String,
    ),
    access_key:        String,
    secret_key:        String,
    region:            String,
    bucket:            String,
    endpoint:          String,
    content_threshold: Float64,
  })
end

CONFIG = Config.from_yaml(File.read("config/config.yml"))

ACCESS_KEY      = CONFIG.access_key
SECRET_KEY      = CONFIG.secret_key
REGION          = CONFIG.region
BUCKET          = CONFIG.bucket
SPACES_ENDPOINT = CONFIG.endpoint

CONTENT_THRESHOLD = CONFIG.content_threshold

PG_URL = URI.new(
  scheme: "postgres",
  user: CONFIG.db[:user],
  password: CONFIG.db[:password],
  host: CONFIG.db[:host],
  port: CONFIG.db[:port],
  path: CONFIG.db[:dbname],
)

PG_DB = DB.open PG_URL

class Worker
  DB.mapping({
    id:             String,
    ip:             String,
    reputation:     Int32,
    disabled:       Bool,
    current_batch:  String?,
    last_committed: Time?,
  })
end

class Batch
  DB.mapping({
    id:           String,
    start_ctid:   String,
    end_ctid:     String,
    finished:     Bool,
    content_size: Int32?,
    videos:       Array(String),
    version:      Int32,
  })
end

get "/" do |env|
  env.response.content_type = "text/html"
  <<-END_HTML
  <html>
  <head>
  <style>
    body {
      margin: 40px auto;
      max-width: 800px;
      padding: 0 10px;
      font-family: Open Sans, Arial;
      color: #454545;
      line-height: 1.2;
    }
  </style>
  </head>
  <body>
    <h2>See <a href="https://github.com/omarroth/archive">here</a> for details</h2>
  </body>
  </html>
  END_HTML
end

get "/api/stats" do |env|
  env.response.content_type = "application/json"
  batch_count = PG_DB.query_one("SELECT count(*) FROM batches", as: Int64)
  batch_finished, content_size = PG_DB.query_one("SELECT count(*), sum(content_size) FROM batches WHERE finished = true", as: {Int64, Int64})
  batch_remaining = batch_count - batch_finished

  estimated_video_count = batch_count * 10000
  estimated_video_finished = batch_finished * 10000
  estimated_video_remaining = estimated_video_count - estimated_video_finished

  worker_count = PG_DB.query_one("SELECT count(*) FROM workers", as: Int64)
  worker_active = PG_DB.query_one("SELECT count(*) FROM workers WHERE (CURRENT_TIMESTAMP - last_committed) < interval '1 hour'", as: Int64)

  response = {
    "batch_count"               => batch_count,
    "batch_finished"            => batch_finished,
    "batch_remaining"           => batch_remaining,
    "content_size"              => content_size,
    "estimated_video_count"     => estimated_video_count,
    "estimated_video_finished"  => estimated_video_finished,
    "estimated_video_remaining" => estimated_video_remaining,
    "worker_count"              => worker_count,
    "worker_active"             => worker_active,
  }.to_pretty_json
  halt env, status_code: 200, response: response
end

get "/api/workers" do |env|
  env.response.content_type = "application/json"

  remote_address = env.as(HTTP::Server::NewContext).remote_address.address
  workers = PG_DB.query_all("SELECT id FROM workers WHERE ip = $1", remote_address, as: String)

  response = {
    "workers" => workers,
  }.to_json
  halt env, status_code: 200, response: response
end

post "/api/workers/create" do |env|
  env.response.content_type = "application/json"

  remote_address = env.as(HTTP::Server::NewContext).remote_address.address
  worker_count = PG_DB.query_one("SELECT count(*) FROM workers WHERE ip = $1", remote_address, as: Int64)

  if worker_count > 1000
    response = {
      "error"      => "Too many workers for IP",
      "error_code" => 1,
    }.to_json
    halt env, status_code: 403, response: response
  end

  worker_id = "#{UUID.random}"
  PG_DB.exec("INSERT INTO workers VALUES ($1, $2, $3, $4)", worker_id, remote_address, 0, false)

  response = {
    "worker_id" => worker_id,
    "s3_url"    => "https://#{BUCKET}.#{REGION}.#{SPACES_ENDPOINT}",
  }.to_json
  halt env, status_code: 200, response: response
end

post "/api/batches" do |env|
  env.response.content_type = "application/json"

  worker_id = env.params.json["worker_id"].as(String)
  worker = PG_DB.query_one?("SELECT * FROM workers WHERE id = $1", worker_id, as: Worker)

  if !worker
    response = {
      "error"      => "Worker does not exist",
      "error_code" => 2,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if worker.disabled
    response = {
      "error"      => "Worker is disabled",
      "error_code" => 3,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if worker.current_batch
    response = {
      "error"      => "Worker must commit #{worker.current_batch}",
      "error_code" => 4,
      "batch_id"   => worker.current_batch,
    }.to_json
    halt env, status_code: 403, response: response
  end

  # Check trusted workers less often
  if rand(worker.reputation + 1) == 0 && PG_DB.query_one("SELECT count(*) FROM batches WHERE finished = true", as: Int64) != 0
    select_finished = true
  elsif PG_DB.query_one("SELECT count(*) FROM batches WHERE finished = false", as: Int64) == 0
    select_finished = true
  else
    select_finished = false
  end

  batch_id, objects = PG_DB.query_one("SELECT id, videos FROM batches WHERE finished = $1 ORDER BY RANDOM() LIMIT 1",
    select_finished, as: {String, Array(String)})

  # Assign worker with batch
  PG_DB.exec("UPDATE workers SET current_batch = $1 WHERE id = $2", batch_id, worker_id)

  response = {
    "batch_id" => batch_id,
    "objects"  => objects,
  }.to_json
  halt env, status_code: 200, response: response
end

post "/api/batches/:batch_id" do |env|
  env.response.content_type = "application/json"

  worker_id = env.params.json["worker_id"].as(String)
  batch_id = env.params.url["batch_id"]

  worker = PG_DB.query_one?("SELECT * FROM workers WHERE id = $1", worker_id, as: Worker)

  if !worker
    response = {
      "error"      => "Worker does not exist",
      "error_code" => 2,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if worker.disabled
    response = {
      "error"      => "Worker is disabled",
      "error_code" => 3,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if batch_id != worker.current_batch
    response = {
      "error"      => "Worker isn't allowed access to #{batch_id}",
      "error_code" => 5,
    }.to_json
    halt env, status_code: 403, response: response
  end

  batch_id, objects = PG_DB.query_one("SELECT id, videos FROM batches WHERE id = $1",
    batch_id, as: {String, Array(String)})

  response = {
    "batch_id" => batch_id,
    "objects"  => objects,
  }.to_json
  halt env, status_code: 200, response: response
end

post "/api/commit" do |env|
  env.response.content_type = "application/json"

  worker_id = env.params.json["worker_id"].as(String)
  batch_id = env.params.json["batch_id"].as(String)
  content_size = env.params.json["content_size"].as(Int64)
  content_size ||= 0

  worker = PG_DB.query_one?("SELECT * FROM workers WHERE id = $1", worker_id, as: Worker)

  if !worker
    response = {
      "error"      => "Worker does not exist",
      "error_code" => 2,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if worker.disabled
    response = {
      "error"      => "Worker is disabled",
      "error_code" => 3,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if batch_id.empty?
    response = {
      "error"      => "Cannot commit with empty batch_id",
      "error_code" => 6,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if batch_id != worker.current_batch
    response = {
      "error"      => "Worker must commit #{worker.current_batch}",
      "error_code" => 4,
      "batch_id"   => worker.current_batch,
    }.to_json
    halt env, status_code: 403, response: response
  end

  batch = PG_DB.query_one?("SELECT * FROM batches WHERE id = $1", worker.current_batch, as: Batch)

  if !batch
    response = {
      "error"      => "Batch #{worker.current_batch} does not exist",
      "error_code" => 7,
    }.to_json
    halt env, status_code: 403, response: response
  end

  object = "#{batch.id}.json.gz"

  if batch.finished && batch.content_size
    if ((content_size - batch.content_size.not_nil!).to_f / batch.content_size.not_nil!.to_f).abs < CONTENT_THRESHOLD
      PG_DB.exec("UPDATE workers SET reputation = reputation + 1, current_batch = NULL, last_committed = $1 WHERE id = $2", Time.now, worker_id)

      response = {
        "upload_url" => "",
      }.to_json
      halt env, status_code: 200, response: response
    elsif worker.reputation > 100
      # Allow a trusted worker to upload a new version to S3

      object = "#{batch.id}.json.gz-#{batch.version}"
      PG_DB.exec("UPDATE batches SET content_size = $1, version = version + 1 WHERE id = $2", content_size, batch.id)
    else
      PG_DB.exec("UPDATE workers SET reputation = reputation - 10 WHERE id = $1", worker.id)
      PG_DB.exec("UPDATE workers SET disabled = true WHERE reputation < 0 AND id = $1", worker.id)

      response = {
        "error"      => "Invalid size for #{batch_id}",
        "error_code" => 8,
        "batch_id"   => batch.id,
      }.to_json
      halt env, status_code: 403, response: response
    end
  end

  options = Awscr::S3::Presigned::Url::Options.new(
    aws_access_key: ACCESS_KEY,
    aws_secret_key: SECRET_KEY,
    region: REGION,
    object: object,
    bucket: "",
    host_name: "#{BUCKET}.#{REGION}.#{SPACES_ENDPOINT}",
    additional_options: {
      "Content-Type"   => "application/gzip",
      "Content-Length" => "#{content_size}",
    }
  )
  url = Awscr::S3::Presigned::Url.new(options).for(:put)

  response = {
    "upload_url" => url,
  }.to_json
  halt env, status_code: 200, response: response
end

post "/api/finalize" do |env|
  env.response.content_type = "application/json"

  worker_id = env.params.json["worker_id"].as(String)
  batch_id = env.params.json["batch_id"].as(String)

  worker = PG_DB.query_one?("SELECT * FROM workers WHERE id = $1", worker_id, as: Worker)

  if !worker
    response = {
      "error"      => "Worker does not exist",
      "error_code" => 2,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if worker.disabled
    response = {
      "error"      => "Worker is disabled",
      "error_code" => 3,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if batch_id.empty?
    response = {
      "error"      => "Cannot commit with empty batch_id",
      "error_code" => 6,
    }.to_json
    halt env, status_code: 403, response: response
  end

  if batch_id != worker.current_batch
    response = {
      "error"      => "Worker must commit #{worker.current_batch}",
      "error_code" => 4,
      "batch_id"   => worker.current_batch,
    }.to_json
    halt env, status_code: 403, response: response
  end

  batch = PG_DB.query_one?("SELECT * FROM batches WHERE id = $1", worker.current_batch, as: Batch)

  if !batch
    response = {
      "error"      => "Batch #{worker.current_batch} does not exist",
      "error_code" => 7,
    }.to_json
    halt env, status_code: 403, response: response
  end

  s3_signer = Awscr::S3::SignerFactory.get(version: :v4, region: REGION, aws_access_key: ACCESS_KEY, aws_secret_key: SECRET_KEY)
  s3_client = Awscr::S3::Http.new(signer: s3_signer, region: REGION, custom_endpoint: "https://#{BUCKET}.#{REGION}.#{SPACES_ENDPOINT}")
  response = s3_client.head("/#{batch.id}.json.gz")
  content_size = response.headers["Content-Length"].to_i

  PG_DB.exec("UPDATE batches SET content_size = $1, finished = $2 WHERE id = $3", content_size, true, batch.id)
  PG_DB.exec("UPDATE workers SET reputation = reputation + 1, current_batch = NULL, last_committed = $1 WHERE id = $2", Time.now, worker_id)

  halt env, status_code: 204, response: ""
end

options "/api/videos/submit" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type"
end

post "/api/videos/submit" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.content_type = "application/json"

  videos = env.params.json["videos"].as(Array(JSON::Any))
  videos = videos.map { |videos| videos.as_s }
  videos.select! { |video| video.match(/[A-Za-z0-9_-]{11}/) }

  exists = PG_DB.query_all("SELECT id FROM videos WHERE id = ANY('{#{videos.join(",")}}')", as: String)
  exists += PG_DB.query_all("SELECT id FROM user_videos WHERE id = ANY('{#{videos.join(",")}}')", as: String)
  videos -= exists

  if !videos.empty?
    args = [] of String
    videos.each_with_index { |video, i| args << "($#{i + 1})" }
    PG_DB.exec("INSERT INTO user_videos VALUES #{args.join(",")} ON CONFLICT DO NOTHING", videos)
  end

  body = {
    "inserted" => videos,
  }.to_json

  halt env, status_code: 200, response: body
end

options "/api/playlists/submit" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type"
end

post "/api/playlists/submit" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.content_type = "application/json"

  playlists = env.params.json["playlists"].as(Array(JSON::Any))
  playlists = playlists.map { |playlist| playlist.as_s }
  # playlists.select! { |playlist| playlist.match(/UC[A-Za-z0-9_-]{22}/) }
  playlists.uniq!

  exists = PG_DB.query_all("SELECT plid FROM playlists WHERE plid = ANY('{#{playlists.join(",")}}')", as: String)
  exists += PG_DB.query_all("SELECT plid FROM user_playlists WHERE plid = ANY('{#{playlists.join(",")}}')", as: String)
  playlists -= exists

  if !playlists.empty?
    args = [] of String
    playlists.each_with_index { |playlist, i| args << "($#{i + 1})" }
    PG_DB.exec("INSERT INTO user_playlists VALUES #{args.join(",")} ON CONFLICT DO NOTHING", playlists)
  end

  body = {
    "inserted" => playlists,
  }.to_json

  halt env, status_code: 200, response: body
end

options "/api/channels/submit" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type"
end

post "/api/channels/submit" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.content_type = "application/json"

  channels = env.params.json["channels"].as(Array(JSON::Any))
  channels = channels.map { |channel| channel.as_s }
  channels.select! { |channel| channel.match(/UC[A-Za-z0-9_-]{22}/) }

  exists = PG_DB.query_all("SELECT ucid FROM channels WHERE ucid = ANY('{#{channels.join(",")}}')", as: String)
  exists += PG_DB.query_all("SELECT ucid FROM user_channels WHERE ucid = ANY('{#{channels.join(",")}}')", as: String)
  channels -= exists

  if !channels.empty?
    args = [] of String
    channels.each_with_index { |video, i| args << "($#{i + 1})" }
    PG_DB.exec("INSERT INTO user_channels VALUES #{args.join(",")} ON CONFLICT DO NOTHING", channels)
  end

  body = {
    "inserted" => channels,
  }.to_json

  halt env, status_code: 200, response: body
end

error 404 do |env|
  env.response.content_type = "application/json"
  {
    "error"      => "404 Not Found",
    "error_code" => 404,
  }.to_pretty_json
end

error 500 do |env|
  env.response.content_type = "application/json"
  {
    "error"      => "500 Internal Server error",
    "error_code" => 500,
  }.to_pretty_json
end

if PG_DB.query_one("SELECT count(*) FROM batches WHERE finished = true", as: Int64) == 0
  puts "WARNING: No completed batches, will not be able to verify workers"
end

# Add redirect if SSL is enabled
if Kemal.config.ssl
  spawn do
    server = HTTP::Server.new do |context|
      redirect_url = "https://#{context.request.host}#{context.request.path}"
      if context.request.query
        redirect_url += "?#{context.request.query}"
      end
      context.response.headers.add("Location", redirect_url)
      context.response.status_code = 301
    end

    server.bind_tcp "0.0.0.0", 80
    server.listen
  end
end

gzip true
Kemal.run
