# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require_relative '../../docker/entrypoint'

RSpec.describe DawarichEntrypoint do
  describe '.sanitize_integer_env' do
    def sanitize(value)
      env = value.nil? ? {} : { 'WEB_CONCURRENCY' => value }
      io = StringIO.new
      described_class.sanitize_integer_env('WEB_CONCURRENCY', '1', env, io)
      [env['WEB_CONCURRENCY'], io.string]
    end

    it 'falls back to the default for an unexpanded compose expression, and warns' do
      value, warning = sanitize('${WEB_CONCURRENCY:-1}')

      expect(value).to eq('1')
      expect(warning).to include('not an integer')
    end

    it 'keeps a valid integer untouched' do
      expect(sanitize('4')).to eq(['4', ''])
    end

    it 'keeps auto untouched' do
      expect(sanitize('auto')).to eq(['auto', ''])
    end

    it 'leaves an unset variable unset' do
      expect(sanitize(nil)).to eq([nil, ''])
    end
  end

  describe '.warn_if_development_env' do
    def warning_for(env)
      io = StringIO.new
      described_class.warn_if_development_env(env, io)
      io.string
    end

    it 'warns a self-hosted instance running in development' do
      expect(warning_for('RAILS_ENV' => 'development', 'SELF_HOSTED' => 'true')).to include('RAILS_ENV=production')
    end

    it 'warns when neither RAILS_ENV nor RACK_ENV is set, as Rails then boots in development' do
      expect(warning_for({})).to include('RAILS_ENV=production')
    end

    it 'warns when RAILS_ENV is empty' do
      expect(warning_for('RAILS_ENV' => '')).to include('RAILS_ENV=production')
    end

    it 'follows RACK_ENV when RAILS_ENV is not set' do
      expect(warning_for('RACK_ENV' => 'production')).to be_empty
    end

    it 'prefers RAILS_ENV over RACK_ENV' do
      expect(warning_for('RAILS_ENV' => 'production', 'RACK_ENV' => 'development')).to be_empty
    end

    it 'stays silent in production and staging' do
      expect(warning_for('RAILS_ENV' => 'production', 'SELF_HOSTED' => 'true')).to be_empty
      expect(warning_for('RAILS_ENV' => 'staging')).to be_empty
    end

    ['1', 'TRUE', 'yes', 'On', 't', '"true"', "'true'", ' true '].each do |value|
      it "treats SELF_HOSTED=#{value.inspect} as self-hosted, like the app does" do
        expect(warning_for('RAILS_ENV' => 'development', 'SELF_HOSTED' => value)).to include('RAILS_ENV=production')
      end
    end

    ['false', '0', 'no', ''].each do |value|
      it "stays silent when SELF_HOSTED=#{value.inspect}" do
        expect(warning_for('RAILS_ENV' => 'development', 'SELF_HOSTED' => value)).to be_empty
      end
    end
  end

  describe '.apply_database_url' do
    it 'splits DATABASE_URL into the variables config/database.yml reads' do
      env = { 'DATABASE_URL' => 'postgis://dawarich:s3cret@db.internal:6432/dawarich_production' }

      described_class.apply_database_url(env)

      expect(env).to include(
        'DATABASE_USERNAME' => 'dawarich', 'DATABASE_PASSWORD' => 's3cret',
        'DATABASE_HOST' => 'db.internal', 'DATABASE_PORT' => '6432', 'DATABASE_NAME' => 'dawarich_production'
      )
    end

    it 'defaults the port to 5432' do
      env = { 'DATABASE_URL' => 'postgres://user:pw@db/app' }

      described_class.apply_database_url(env)

      expect(env['DATABASE_PORT']).to eq('5432')
    end

    it 'leaves the individual variables alone without DATABASE_URL' do
      env = { 'DATABASE_HOST' => 'dawarich_db' }

      described_class.apply_database_url(env)

      expect(env).to eq('DATABASE_HOST' => 'dawarich_db')
    end
  end

  describe '.ownership_target' do
    it 'defaults to the image user' do
      expect(described_class.ownership_target({})).to eq([65_532, 65_532])
    end

    it 'uses PUID and PGID when set' do
      expect(described_class.ownership_target('PUID' => '1000', 'PGID' => '100')).to eq([1000, 100])
    end

    it 'rejects a non-numeric PUID instead of chowning to a wrong user' do
      expect { described_class.ownership_target('PUID' => 'abc') }.to raise_error(ArgumentError)
    end
  end

  describe '.detect_mode' do
    it 'takes the mode from the first argument and leaves the command' do
      args = %w[run bin/rails server]

      expect(described_class.detect_mode(args, '/usr/local/bin/dawarich-entrypoint')).to eq('run')
      expect(args).to eq(%w[bin/rails server])
    end

    it 'maps the legacy script names that compose files still reference' do
      expect(described_class.detect_mode(%w[bin/rails server], '/usr/local/bin/web-entrypoint.sh')).to eq('web')
      expect(described_class.detect_mode([], 'sidekiq-entrypoint.sh')).to eq('sidekiq')
      expect(described_class.detect_mode(%w[bin/rails server], 'cloud-entrypoint.sh')).to eq('cloud')
    end

    it 'returns nil for an unknown invocation' do
      expect(described_class.detect_mode(%w[bin/rails server], 'dawarich-entrypoint')).to be_nil
    end
  end

  describe '.sync_assets' do
    around do |example|
      Dir.mktmpdir do |dir|
        @app = dir
        example.run
      end
    end

    let(:io) { StringIO.new }

    it 'replaces old compiled assets with the image copy and keeps other public files' do
      FileUtils.mkdir_p(File.join(@app, 'public_dist/assets'))
      File.write(File.join(@app, 'public_dist/assets/app-new.js'), 'new')
      File.write(File.join(@app, 'public_dist/robots.txt'), 'robots')
      FileUtils.mkdir_p(File.join(@app, 'public/assets'))
      File.write(File.join(@app, 'public/assets/app-old.js'), 'old')
      File.write(File.join(@app, 'public/uploaded.txt'), 'user file')

      described_class.sync_assets(@app, io)

      expect(Dir.children(File.join(@app, 'public/assets'))).to eq(['app-new.js'])
      expect(File.read(File.join(@app, 'public/robots.txt'))).to eq('robots')
      expect(File.read(File.join(@app, 'public/uploaded.txt'))).to eq('user file')
    end

    it 'warns and leaves public alone when the image copy is missing' do
      FileUtils.mkdir_p(File.join(@app, 'public/assets'))

      described_class.sync_assets(@app, io)

      expect(io.string).to include('NOT synced')
      expect(Dir.exist?(File.join(@app, 'public/assets'))).to be(true)
    end

    it 'stops with upgrade guidance when the public volume is not writable' do
      skip 'root can write anywhere' if Process.uid.zero?

      FileUtils.mkdir_p(File.join(@app, 'public_dist'))
      FileUtils.mkdir_p(File.join(@app, 'public'))
      File.chmod(0o555, File.join(@app, 'public'))

      expect { described_class.sync_assets(@app, io) }
        .to raise_error(SystemExit).and output(/dawarich_init/).to_stderr
    ensure
      File.chmod(0o755, File.join(@app, 'public')) if File.exist?(File.join(@app, 'public'))
    end
  end

  describe '.fix_ownership' do
    it 'skips paths that already belong to the target user' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'public'))
        io = StringIO.new

        described_class.fix_ownership(dir, Process.uid, Process.gid, io)

        expect(io.string).to be_empty
      end
    end
  end
end
