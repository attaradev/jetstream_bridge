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
    original_program_name = $PROGRAM_NAME
    original_env = {
      disable: ENV.fetch('JETSTREAM_BRIDGE_DISABLE_AUTOSTART', nil),
      force: ENV.fetch('JETSTREAM_BRIDGE_FORCE_AUTOSTART', nil),
      nats_urls: ENV.fetch('NATS_URLS', nil)
    }
    example.run
    $PROGRAM_NAME = original_program_name
    ENV['JETSTREAM_BRIDGE_DISABLE_AUTOSTART'] = original_env[:disable]
    ENV['JETSTREAM_BRIDGE_FORCE_AUTOSTART'] = original_env[:force]
    ENV['NATS_URLS'] = original_env[:nats_urls]
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
    allow(described_class).to receive(:auto_enable_test_mode!).and_return(true)
    allow(JetstreamBridge).to receive(:startup!)
  end

  describe '.configure_logger!' do
    it 'sets config logger from Rails.logger when missing' do
      JetstreamBridge.config.logger = nil

      described_class.configure_logger!

      expect(JetstreamBridge.config.logger).to eq(logger_instance)
    end

    it 'does not override an existing logger' do
      custom = Logger.new(StringIO.new)
      JetstreamBridge.config.logger = custom

      described_class.configure_logger!

      expect(JetstreamBridge.config.logger).to eq(custom)
    end
  end

  describe '.attach_active_record_hooks!' do
    it 'registers model codec setup on ActiveRecord load' do
      reloader = Module.new do
        class << self
          attr_reader :callbacks

          def to_prepare(&block)
            (@callbacks ||= []) << block
          end

          def run_callbacks
            (@callbacks || []).each(&:call)
          end
        end
      end

      active_support = Module.new do
        class << self
          attr_accessor :stored_block
        end

        def self.on_load(_name, &block)
          self.stored_block = block
        end
      end

      stub_const('ActiveSupport', active_support)
      stub_const('ActiveSupport::Reloader', reloader)
      allow(JetstreamBridge::ModelCodecSetup).to receive(:apply!)

      described_class.attach_active_record_hooks!
      ActiveSupport.stored_block.call
      ActiveSupport::Reloader.run_callbacks

      expect(JetstreamBridge::ModelCodecSetup).to have_received(:apply!)
    end
  end

  describe '.auto_enable_test_mode?' do
    before do
      allow(described_class).to receive(:rails_test?).and_return(true)
    end

    it 'returns true when in test env and NATS_URLS is blank' do
      ENV['NATS_URLS'] = ''
      allow(JetstreamBridge::TestHelpers).to receive(:test_mode?).and_return(false)

      expect(described_class.auto_enable_test_mode?).to be(true)
    end

    it 'returns false when test mode already enabled' do
      ENV['NATS_URLS'] = ''
      allow(JetstreamBridge::TestHelpers).to receive(:test_mode?).and_return(true)

      expect(described_class.auto_enable_test_mode?).to be(false)
    end
  end

  describe '.auto_enable_test_mode!' do
    before do
      allow(described_class).to receive(:auto_enable_test_mode!).and_call_original
      allow(described_class).to receive(:auto_enable_test_mode?).and_return(true)
      allow(JetstreamBridge::Logging).to receive(:info)
      allow(JetstreamBridge::TestHelpers).to receive(:enable_test_mode!)
    end

    it 'logs and enables test mode when conditions are met' do
      described_class.auto_enable_test_mode!

      expect(JetstreamBridge::Logging).to have_received(:info).with(
        a_string_including('Auto-enabling test mode'),
        tag: 'JetstreamBridge::Railtie'
      )
      expect(JetstreamBridge::TestHelpers).to have_received(:enable_test_mode!)
    end
  end

  describe '.autostart_skip_reason' do
    it 'returns unknown when no skip flags are set' do
      JetstreamBridge.config.lazy_connect = false
      ENV['JETSTREAM_BRIDGE_DISABLE_AUTOSTART'] = nil
      $PROGRAM_NAME = 'rails'

      expect(described_class.autostart_skip_reason).to eq('unknown')
    end
  end

  describe '.log_development_connection_details!' do
    it 'logs connection details in development' do
      allow(env_double).to receive(:development?).and_return(true)

      # Set up facade with connected state
      mock_connection_manager = instance_double(
        JetstreamBridge::ConnectionManager,
        state: :connected,
        health_check: {
          connected: true,
          state: :connected,
          connected_at: Time.now,
          last_error: nil,
          last_error_at: nil
        }
      )
      facade = JetstreamBridge.instance_variable_get(:@facade) || JetstreamBridge::Facade.new
      JetstreamBridge.instance_variable_set(:@facade, facade)
      facade.instance_variable_set(:@connection_manager, mock_connection_manager)

      allow(JetstreamBridge.config).to receive_messages(
        nats_urls: 'nats://example:4222',
        stream_name: 'dev-stream',
        source_subject: 'dev.source',
        destination_subject: 'dev.dest'
      )

      described_class.log_development_connection_details!

      expect(log_output.string).to include('Connection state: connected')
      expect(log_output.string).to include('Connected to: nats://example:4222')
      expect(log_output.string).to include('Stream: dev-stream')
      expect(log_output.string).to include('Publishing to: dev.source')
      expect(log_output.string).to include('Consuming from: dev.dest')
    end
  end

  describe '.register_shutdown_hook!' do
    before do
      allow(described_class).to receive(:register_shutdown_hook!).and_call_original
      described_class.instance_variable_set(:@shutdown_hook_registered, nil)
      allow(Kernel).to receive(:at_exit)
    end

    it 'registers at_exit only once' do
      expect { described_class.register_shutdown_hook! }
        .to change { described_class.instance_variable_get(:@shutdown_hook_registered) }.from(nil).to(true)

      expect { described_class.register_shutdown_hook! }
        .not_to(change { described_class.instance_variable_get(:@shutdown_hook_registered) })
    end
  end

  describe '.rails_test?' do
    it 'returns true when Rails.env.test? is true' do
      allow(env_double).to receive(:test?).and_return(true)

      expect(described_class.rails_test?).to be(true)
    end
  end

  describe '.rails_console?' do
    it 'detects Rails console constant' do
      stub_const('Rails::Console', Class.new)

      expect(described_class.rails_console?).to be(true)
    end
  end

  describe '.active_logger' do
    it 'falls back to internal logger when Rails logger is unavailable' do
      Rails.logger = nil
      allow(Rails).to receive(:respond_to?).and_return(false)
      allow(JetstreamBridge::Logging).to receive(:logger).and_return(:fallback_logger)

      expect(described_class.send(:active_logger)).to eq(:fallback_logger)
    end
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

    it 'returns false when force flag is set even if rake task' do
      $PROGRAM_NAME = 'rake'
      ENV['JETSTREAM_BRIDGE_FORCE_AUTOSTART'] = '1'
      expect(described_class.autostart_disabled?).to be(false)
    end

    it 'does not skip autostart for Rails console by default' do
      stub_const('Rails::Console', Class.new)
      JetstreamBridge.config.lazy_connect = false
      expect(described_class.autostart_disabled?).to be(false)
    end

    it 'skips autostart for rake tasks by default' do
      $PROGRAM_NAME = 'rake'
      JetstreamBridge.config.lazy_connect = false
      expect(described_class.autostart_disabled?).to be(true)
      expect(described_class.autostart_skip_reason).to eq('rake task')
    end
  end

  describe '.boot_bridge!' do
    it 'skips startup and logs reason when autostart is disabled' do
      JetstreamBridge.config.lazy_connect = true
      expect(JetstreamBridge).not_to receive(:connect!)
      expect(JetstreamBridge::Logging).to receive(:info).with(
        a_string_including('Auto-start skipped'),
        tag: 'JetstreamBridge::Railtie'
      )
      described_class.boot_bridge!
    end

    it 'starts up when autostart is allowed' do
      allow(described_class).to receive(:autostart_disabled?).and_return(false)
      expect(JetstreamBridge).to receive(:connect!)
      described_class.boot_bridge!
    end
  end
end
