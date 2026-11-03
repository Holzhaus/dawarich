#!/usr/local/bin/ruby
# frozen_string_literal: true

# Container entrypoint for the Distroless image, which has no shell. It replaces
# the former web-, sidekiq- and cloud-entrypoint.sh scripts. Those names are
# kept as symlinks to this file, so compose files that still say
# `entrypoint: web-entrypoint.sh` keep working.
#
# Modes (the first argument, or derived from the name the file is run as):
#   init     One-shot setup. When started as root: give the writable volumes to
#            PUID:PGID and drop to that user. Then sync static assets and
#            create, migrate and seed the database, and exit.
#   run      Wait for the database, then exec the given command.
#   web      init's asset and database steps, then exec the given command
#            (what web-entrypoint.sh did).
#   sidekiq  Wait for the database, then exec Sidekiq.
#   cloud    Drop root to 32767:32767, then exec the given command. No setup.

require 'fileutils'

module DawarichEntrypoint
  MODES = %w[init run web sidekiq cloud].freeze
  LEGACY_NAMES = {
    'web-entrypoint.sh' => 'web',
    'sidekiq-entrypoint.sh' => 'sidekiq',
    'cloud-entrypoint.sh' => 'cloud'
  }.freeze

  # Writable paths under APP_PATH: the compose volumes (public, storage,
  # tmp/imports/watched) and the directories the app writes to at runtime.
  OWNED_PATHS = %w[public storage tmp tmp/imports/watched db log].freeze
  # The `nonroot` user of the Distroless base image.
  DEFAULT_UID = 65_532
  CLOUD_UID = 32_767
  INTEGER_ENV_DEFAULTS = { 'WEB_CONCURRENCY' => '1', 'BACKGROUND_PROCESSING_CONCURRENCY' => '3' }.freeze
  TRUTHY = %w[true 1 yes on t].freeze

  DEVELOPMENT_WARNING = <<~TEXT
    ⚠️ Dawarich is running with RAILS_ENV=development ⚠️
    Development mode is meant for working on Dawarich itself: code is loaded on
    demand and reloaded when it changes, and every SQL query is logged at debug
    level together with the line of code that ran it.

    Self-hosted instances should run with RAILS_ENV=production, the default in
    docker/docker-compose.yml since Dawarich 1.3.0. Compose files from earlier
    versions default to development, so set RAILS_ENV=production explicitly for
    both the app and the Sidekiq container.

    Read this before switching an existing instance:
    https://dawarich.app/docs/self-hosting/environment-variables/#switching-an-existing-instance-to-production
  TEXT

  UNWRITABLE_PUBLIC = <<~TEXT
    ❌ %<path>s is not writable by uid %<uid>d.
    The Dawarich image now runs as a non-root user, and volumes created by
    earlier versions belong to root. Update to the current
    docker/docker-compose.yml: its dawarich_init service gives the volumes to
    PUID:PGID before the app starts. See "Distroless image" in the upgrade
    notes of CHANGELOG.md.
  TEXT

  module_function

  def main(argv, program_name: $PROGRAM_NAME, env: ENV)
    # Container logs are a pipe, not a TTY: without this, progress lines only
    # appear when the process exits, out of order with stderr.
    $stdout.sync = true
    args = argv.dup
    mode = detect_mode(args, program_name)
    abort "Usage: dawarich-entrypoint {#{MODES.join('|')}} [command...]" unless mode

    env.delete('BUNDLE_PATH')
    env.delete('BUNDLE_BIN')
    app_path = env.fetch('APP_PATH', '/var/app')
    Dir.chdir(app_path)

    return run_cloud(args) if mode == 'cloud'

    become_app_user(app_path, env)
    warn_if_development_env(env)
    INTEGER_ENV_DEFAULTS.each { |name, default| sanitize_integer_env(name, default, env) }
    apply_database_url(env)

    case mode
    when 'init'
      setup(app_path, env)
      puts '✅ Setup finished.'
    when 'web'
      setup(app_path, env)
      exec_bundle(args)
    when 'run'
      wait_for_database(env)
      remove_stale_pid(app_path)
      exec_bundle(args)
    when 'sidekiq'
      puts "⚠️ Starting Sidekiq in #{env['RAILS_ENV']} environment ⚠️"
      wait_for_database(env)
      exec_bundle(['sidekiq'])
    end
  end

  def detect_mode(args, program_name)
    return args.shift if MODES.include?(args.first)

    LEGACY_NAMES[File.basename(program_name.to_s)]
  end

  # Replaces the shell guard's sanitize_integer_env: compose files whose
  # variable interpolation failed pass the literal "${NAME:-1}", which would
  # crash Puma or Sidekiq. Fall back to the default and say so.
  def sanitize_integer_env(name, default, env = ENV, io = $stderr)
    value = env[name].to_s
    return if value.empty? || value == 'auto' || value.match?(/\A\d+\z/)

    io.puts "⚠️ #{name}='#{value}' is not an integer (compose variable interpolation may have failed) " \
            "— falling back to #{default}"
    env[name] = default
  end

  def truthy?(value)
    TRUTHY.include?(value.to_s.delete(%q("')).strip.downcase)
  end

  # RAILS_ENV wins over RACK_ENV, and an empty value counts as unset, matching
  # how Rails picks its environment. SELF_HOSTED defaults to true when unset,
  # but an empty value is not self-hosted.
  def development_env?(env = ENV)
    rails_env = env['RAILS_ENV'].to_s
    rails_env = env['RACK_ENV'].to_s if rails_env.empty?
    rails_env = 'development' if rails_env.empty?

    rails_env == 'development' && truthy?(env.fetch('SELF_HOSTED', 'true'))
  end

  def warn_if_development_env(env = ENV, io = $stderr)
    io.print DEVELOPMENT_WARNING if development_env?(env)
  end

  # config/database.yml reads DATABASE_HOST, _PORT, _USERNAME, _PASSWORD and
  # _NAME, so split DATABASE_URL into those, as the shell entrypoints did.
  def apply_database_url(env = ENV)
    url = env['DATABASE_URL'].to_s
    return if url.empty?

    credentials, host_path = url.sub(%r{\A[^:]*://}, '').split('@', 2)
    username, password = credentials.split(':', 2)
    host_port, name = host_path.to_s.split('/', 2)
    host, port = host_port.to_s.split(':', 2)

    env['DATABASE_USERNAME'] = username
    env['DATABASE_PASSWORD'] = password if password
    env['DATABASE_NAME'] = name
    env['DATABASE_HOST'] = host
    env['DATABASE_PORT'] = port || '5432'
  end

  def ownership_target(env = ENV)
    %w[PUID PGID].map do |name|
      value = env[name].to_s.strip
      value.empty? ? DEFAULT_UID : Integer(value, 10)
    end
  end

  # As root (the init service, or a legacy setup that runs the app as root):
  # give the writable paths to PUID:PGID and continue as that user. As any
  # other user, run as is.
  def become_app_user(app_path, env)
    return unless Process.uid.zero?

    uid, gid = ownership_target(env)
    fix_ownership(app_path, uid, gid)
    drop_privileges(uid, gid)
  end

  def fix_ownership(app_path, uid, gid, io = $stdout)
    OWNED_PATHS.each do |relative|
      path = File.join(app_path, relative)
      next unless File.directory?(path)
      next if File.stat(path).uid == uid

      io.puts "🔑 Adjusting ownership of #{path} to #{uid}:#{gid}..."
      FileUtils.chown_R(uid, gid, path)
    end
  end

  def drop_privileges(uid, gid)
    Process.groups = [gid]
    Process::GID.change_privilege(gid)
    Process::UID.change_privilege(uid)
  end

  def run_cloud(args)
    drop_privileges(CLOUD_UID, CLOUD_UID) if Process.uid.zero?
    exec_bundle(args)
  end

  def setup(app_path, env)
    puts "⚠️ Starting Rails environment: #{env['RAILS_ENV']} ⚠️"
    remove_stale_pid(app_path)
    sync_assets(app_path)
    wait_for_database(env, create: true)

    puts 'Running primary database migrations...'
    bundle!('rails', 'db:migrate')
    puts 'Running DATA migrations...'
    bundle!('rake', 'data:migrate')
    puts 'Running seeds...'
    bundle!('rails', 'db:seed')
  end

  def remove_stale_pid(app_path)
    FileUtils.rm_f(File.join(app_path, 'tmp/pids/server.pid'))
  end

  # Copy the pristine public/ staged in the image into the persistent public
  # volume, so new and updated files reach it. Old compiled assets are removed
  # first so stale files never persist.
  def sync_assets(app_path, io = $stdout)
    dist = File.join(app_path, 'public_dist')
    public_dir = File.join(app_path, 'public')

    unless File.directory?(dist)
      io.puts "⚠️ #{dist} not found — static assets were NOT synced. " \
              'The public volume may keep serving assets from a previous version.'
      return
    end

    abort format(UNWRITABLE_PUBLIC, path: public_dir, uid: Process.uid) unless File.writable?(public_dir)

    io.puts '📦 Syncing static assets to public volume...'
    FileUtils.rm_rf(File.join(public_dir, 'assets'))
    FileUtils.cp_r(Dir.glob(File.join(dist, '*')), public_dir)
    io.puts '✅ Static assets synced!'
  end

  # Retries until the database accepts connections. With create: true, also
  # creates it when the server is up but the database does not exist yet.
  def wait_for_database(env, create: false)
    require 'bundler/setup'
    require 'pg'

    params = connection_params(env)
    puts "⏳ Waiting for database #{params[:dbname]} to be ready..."
    loop do
      PG.connect(**params).close
      puts "✅ PostgreSQL database #{params[:dbname]} is ready!"
      return
    rescue PG::Error => e
      if create && e.message.include?('does not exist')
        create_database(params)
      else
        warn "Postgres database #{params[:dbname]} is unavailable - retrying..."
        sleep 2
      end
    end
  end

  def connection_params(env)
    {
      host: env['DATABASE_HOST'], port: env['DATABASE_PORT'] || '5432',
      user: env['DATABASE_USERNAME'], password: env['DATABASE_PASSWORD'],
      dbname: env['DATABASE_NAME'], connect_timeout: 5
    }
  end

  def create_database(params)
    puts "Attempting to create database #{params[:dbname]}..."
    PG.connect(**params, dbname: 'postgres') do |connection|
      connection.exec("CREATE DATABASE #{connection.quote_ident(params[:dbname])}")
    end
  rescue PG::Error => e
    warn "Note: database #{params[:dbname]} may already exist or couldn't be created now (#{e.message.strip})"
    sleep 2
  end

  def bundle!(*args)
    system('bundle', 'exec', *args, exception: true)
  end

  def exec_bundle(args)
    abort 'dawarich-entrypoint: no command given' if args.empty?

    exec('bundle', 'exec', *args)
  end
end

# Run only when executed (directly or through a legacy-name symlink), not when
# a spec requires this file.
DawarichEntrypoint.main(ARGV) if File.file?($PROGRAM_NAME) && File.realpath($PROGRAM_NAME) == File.realpath(__FILE__)
