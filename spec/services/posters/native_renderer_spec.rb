# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Posters::NativeRenderer do
  let(:poster) { create(:poster, settings: settings) }
  let(:settings) do
    {
      'lat' => 52.49, 'lon' => 13.39, 'distance' => 15_000,
      'theme' => 'autumn',
      'start_at' => '2025-10-01T00:00:00Z', 'end_at' => '2025-10-31T23:59:59Z'
    }
  end
  let(:track) do
    { 'type' => 'MultiLineString', 'coordinates' => [[[13.28, 52.44], [13.5, 52.51]]] }
  end
  let(:fake_command) { ['ruby', Rails.root.join('spec/fixtures/scripts/fake_poster_renderer.rb').to_s] }

  def build_renderer(command: fake_command)
    described_class.new(
      poster: poster,
      track: track,
      distance: 15_000,
      route_opacity: 0.6,
      subtitle: '1 Oct 2025 – 31 Oct 2025',
      command: command
    )
  end

  describe '#call' do
    it 'renders a job carrying theme tokens, track, view, and text' do
      result = build_renderer.call
      job = JSON.parse(result[:png])

      expect(job['tokens']['name']).to eq('Autumn')
      expect(job['trackGeojson']['geometry']['type']).to eq('MultiLineString')
      expect(job['view']).to include('lat' => 52.49, 'lon' => 13.39, 'distance' => 15_000)
      expect(job['trackOpacity']).to eq(0.6)
      expect(job['text']).to include('title' => 'Berlin', 'subtitle' => '1 Oct 2025 – 31 Oct 2025')
      expect(job['output']).to include('widthMm' => 300, 'heightMm' => 400)
      expect(result[:pdf]).to eq('PDF:Berlin')
    end

    it 'carries the track width multiplier into the job' do
      job = JSON.parse(
        described_class.new(
          poster: poster, track: track, distance: 15_000, route_opacity: 0.6,
          route_width: 2.5, subtitle: '1 Oct 2025 – 31 Oct 2025', command: fake_command
        ).call[:png]
      )

      expect(job['trackWidth']).to eq(2.5)
    end

    it 'defaults the track width multiplier to 1' do
      job = JSON.parse(build_renderer.call[:png])

      expect(job['trackWidth']).to eq(1)
    end

    it 'renders the explicit settings title when present' do
      poster.settings['title'] = 'My Trip'

      job = JSON.parse(build_renderer.call[:png])

      expect(job['text']['title']).to eq('My Trip')
    end

    it 'renders a blank title when the settings title is blank (untitled poster)' do
      poster.update!(name: 'Untitled poster', settings: poster.settings.merge('title' => ''))

      job = JSON.parse(build_renderer.call[:png])

      expect(job['text']['title']).to eq('')
    end

    it 'carries the saved trip stats line into the job text' do
      poster.settings['stats'] = '27.4 km'

      job = JSON.parse(build_renderer.call[:png])

      expect(job['text']['stats']).to eq('27.4 km')
    end

    it 'renders no stats line when the poster was saved without one' do
      job = JSON.parse(build_renderer.call[:png])

      expect(job['text']['stats']).to eq('')
    end

    it 'raises when the renderer process fails' do
      renderer = build_renderer(command: ['ruby', '-e', 'warn "boom"; exit 1'])

      expect { renderer.call }.to raise_error(described_class::Error, /boom/)
    end

    it 'terminates a renderer that exceeds the timeout' do
      stub_const("#{described_class}::RENDER_TIMEOUT", 0.05)
      renderer = build_renderer(command: ['ruby', '-e', 'sleep 0.3'])

      expect { renderer.call }.to raise_error(described_class::Error, /timed out after 0.05 seconds/)
    end

    it 'times out when the process leader exits but a descendant retains its pipes' do
      stub_const("#{described_class}::RENDER_TIMEOUT", 0.2)
      command = [
        'ruby', '-rrbconfig', '-e',
        'Process.spawn(RbConfig.ruby, "-e", "sleep 0.5", out: $stdout, err: $stderr)'
      ]

      expect { build_renderer(command:).call }
        .to raise_error(described_class::Error, /timed out after 0.2 seconds/)
    end

    it 'kills TERM-resistant descendants after a renderer timeout' do
      stub_const("#{described_class}::RENDER_TIMEOUT", 0.2)
      pid_file = Tempfile.new('poster-renderer-child')
      ready_path = "#{pid_file.path}.ready"
      child_code = 'trap("TERM") {}; File.write(ARGV.fetch(0), "ready"); sleep 5'
      parent_code = [
        "child = Process.spawn(RbConfig.ruby, \"-e\", #{child_code.inspect}, #{ready_path.inspect}, " \
        'out: File::NULL, err: File::NULL)',
        "sleep 0.01 until File.exist?(#{ready_path.inspect})",
        'File.write(ARGV.fetch(0), child)',
        'sleep 5'
      ].join('; ')
      command = ['ruby', '-rrbconfig', '-e', parent_code, pid_file.path]

      expect { build_renderer(command:).call }
        .to raise_error(described_class::Error, /timed out after 0.2 seconds/)

      child_pid = File.read(pid_file.path).to_i
      child_running = lambda do
        state = IO.popen(['ps', '-o', 'stat=', '-p', child_pid.to_s], &:read).strip
        state.present? && !state.start_with?('Z')
      end
      child_stopped = 50.times.any? do
        break true unless child_running.call

        sleep 0.01
        false
      end
      expect(child_stopped).to be(true)
    ensure
      Process.kill('KILL', child_pid) if child_pid&.positive? && child_running&.call
      File.delete(ready_path) if ready_path && File.exist?(ready_path)
      pid_file&.close!
    end

    it 'raises when the theme tokens are unknown' do
      poster.settings['theme'] = 'nonexistent_theme'

      expect { build_renderer.call }.to raise_error(described_class::Error, /theme/i)
    end

    it 'explains how to configure the sidecar when the local renderer is missing' do
      renderer = build_renderer(command: ['/nonexistent/render.sh'])

      expect { renderer.call }.to raise_error(described_class::Error, /RENDERER_URL/)
    end
  end

  context 'with the renderer sidecar configured' do
    before { stub_const('ENV', ENV.to_hash.merge('RENDERER_URL' => 'http://renderer:3100')) }

    def remote_renderer
      described_class.new(
        poster: poster, track: track, distance: 15_000, route_opacity: 0.6, subtitle: '1 Oct 2025 – 31 Oct 2025'
      )
    end

    it 'sends the job to the sidecar and returns the decoded PNG and PDF' do
      request = stub_request(:post, 'http://renderer:3100/posters')
                .with { |req| JSON.parse(req.body).dig('tokens', 'name') == 'Autumn' }
                .to_return(status: 200, body: { png: ['PNG-bytes'].pack('m0'), pdf: ['PDF-bytes'].pack('m0') }.to_json)

      expect(remote_renderer.call).to eq(png: 'PNG-bytes', pdf: 'PDF-bytes')
      expect(request).to have_been_made.once
    end

    it 'asks for a PDF and carries the view and text in the job' do
      stub_request(:post, 'http://renderer:3100/posters')
        .to_return(status: 200, body: { png: '', pdf: '' }.to_json)

      remote_renderer.call

      expect(
        a_request(:post, 'http://renderer:3100/posters').with do |req|
          job = JSON.parse(req.body)
          job['output']['pdf'].present? && job['view']['distance'] == 15_000 && job['text']['title'] == 'Berlin'
        end
      ).to have_been_made
    end

    it 'raises with the sidecar error message when rendering fails' do
      stub_request(:post, 'http://renderer:3100/posters')
        .to_return(status: 500, body: { error: 'GL context lost' }.to_json)

      expect { remote_renderer.call }.to raise_error(described_class::Error, /GL context lost/)
    end

    it 'raises a timeout error when the sidecar does not answer in time' do
      stub_request(:post, 'http://renderer:3100/posters').to_timeout

      expect { remote_renderer.call }.to raise_error(described_class::Error, /timed out after 180 seconds/)
    end

    it 'raises when the sidecar is unreachable' do
      stub_request(:post, 'http://renderer:3100/posters').to_raise(Errno::ECONNREFUSED)

      expect { remote_renderer.call }.to raise_error(described_class::Error, /unavailable/)
    end
  end
end
