# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge/rails/integration'
require 'logger'
require 'stringio'

RSpec.describe JetstreamBridge::Rails::Integration do
  let(:env_double) { instance_double('Env', test?: false, development?: false) }
  let(:log_output) { StringIO.new }
  let(:logger_instance) { Logger.new(log_output) }

  around do |example|
    original_env = {
      disable: ENV.fetch('JETSTREAM_BRIDGE_DISABLE_AUTOSTART', nil),
      force: ENV.fetch('JETSTREAM_BRIDGE_FORCE_AUTOSTART', nil)
    }
    example.run
    ENV['JETSTREAM_BRIDGE_DISABLE_AUTOSTART'] = original_env[:disable]
    ENV['JETSTREAM_BRIDGE_FORCE_AUTOSTART'] = original_env[:force]
  end

  before do
    rails_mod = Module.new do
      class << self
        attr_accessor :env, :logger
      end
    end
    rails_mod.env = env_double
    rails_mod.logger = logger_instance

    stub_const('Rails', rails_mod)
    allow(JetstreamBridge.config).to receive(:validate!)
    allow(described_class).to receive(:register_shutdown_hook!).and_return(true)
    allow(described_class).to receive(:auto_enable_test_mode!).and_return(true)
    allow(JetstreamBridge).to receive(:startup!)
  end

  describe '.autostart_disabled?' do
    it 'returns true when lazy_connect is enabled' do
      JetstreamBridge.config.lazy_connect = true
      expect(described_class.autostart_disabled?).to be(true)
      expect(described_class.autostart_skip_reason).to eq('lazy_connect enabled')
    end

    it 'returns true when disable flag is set' do
      JetstreamBridge.config.lazy_connect = false
      ENV['JETSTREAM_BRIDGE_DISABLE_AUTOSTART'] = '1'
      expect(described_class.autostart_disabled?).to be(true)
      expect(described_class.autostart_skip_reason).to eq('JETSTREAM_BRIDGE_DISABLE_AUTOSTART set')
    end

    it 'returns false when force flag is set even if console/rake' do
      stub_const('Rails::Console', Class.new)
      ENV['JETSTREAM_BRIDGE_FORCE_AUTOSTART'] = '1'
      expect(described_class.autostart_disabled?).to be(false)
    end

    it 'skips autostart for Rails console by default' do
      stub_const('Rails::Console', Class.new)
      JetstreamBridge.config.lazy_connect = false
      expect(described_class.autostart_disabled?).to be(true)
      expect(described_class.autostart_skip_reason).to eq('Rails console')
    end
  end

  describe '.boot_bridge!' do
    it 'skips startup and logs reason when autostart is disabled' do
      JetstreamBridge.config.lazy_connect = true
      expect(JetstreamBridge).not_to receive(:startup!)
      expect(JetstreamBridge::Logging).to receive(:info).with(
        a_string_including('Auto-start skipped'),
        tag: 'JetstreamBridge::Railtie'
      )
      described_class.boot_bridge!
    end

    it 'starts up when autostart is allowed' do
      allow(described_class).to receive(:autostart_disabled?).and_return(false)
      expect(JetstreamBridge).to receive(:startup!)
      described_class.boot_bridge!
    end
  end
end
