# frozen_string_literal: true

require 'jetstream_bridge/errors'

RSpec.describe 'JetstreamBridge Error Hierarchy' do
  describe JetstreamBridge::Error do
    it 'is a StandardError' do
      expect(described_class).to be < StandardError
    end

    it 'can be raised with a message' do
      expect { raise described_class, 'test error' }.to raise_error(described_class, 'test error')
    end
  end

  describe JetstreamBridge::ConfigurationError do
    it 'inherits from JetstreamBridge::Error' do
      expect(described_class).to be < JetstreamBridge::Error
    end

    it 'can be raised with configuration details' do
      expect do
        raise described_class, 'nats_urls is required'
      end.to raise_error(described_class, 'nats_urls is required')
    end
  end

  describe JetstreamBridge::InvalidSubjectError do
    it 'inherits from ConfigurationError' do
      expect(described_class).to be < JetstreamBridge::ConfigurationError
    end

    it 'indicates subject validation failure' do
      expect do
        raise described_class, 'subject cannot contain wildcards'
      end.to raise_error(described_class, 'subject cannot contain wildcards')
    end
  end

  describe JetstreamBridge::MissingConfigurationError do
    it 'inherits from ConfigurationError' do
      expect(described_class).to be < JetstreamBridge::ConfigurationError
    end

    it 'indicates missing required configuration' do
      expect do
        raise described_class, 'destination_app is required'
      end.to raise_error(described_class, 'destination_app is required')
    end
  end

  describe JetstreamBridge::ConnectionError do
    it 'inherits from JetstreamBridge::Error' do
      expect(described_class).to be < JetstreamBridge::Error
    end

    it 'can include connection details' do
      expect do
        raise described_class, 'Failed to connect to nats://localhost:4222'
      end.to raise_error(described_class, /Failed to connect/)
    end
  end

  describe JetstreamBridge::PublishError do
    it 'inherits from JetstreamBridge::Error' do
      expect(described_class).to be < JetstreamBridge::Error
    end

    it 'indicates publish operation failure' do
      expect do
        raise described_class, 'Failed to publish event'
      end.to raise_error(described_class, 'Failed to publish event')
    end
  end

  describe JetstreamBridge::ConsumerError do
    it 'inherits from JetstreamBridge::Error' do
      expect(described_class).to be < JetstreamBridge::Error
    end

    it 'indicates consumer operation failure' do
      expect do
        raise described_class, 'Consumer subscription failed'
      end.to raise_error(described_class, 'Consumer subscription failed')
    end
  end

  describe JetstreamBridge::StreamNotFoundError do
    it 'inherits from TopologyError' do
      expect(described_class).to be < JetstreamBridge::TopologyError
    end

    it 'indicates stream not found' do
      expect do
        raise described_class, 'Stream not found'
      end.to raise_error(described_class, 'Stream not found')
    end
  end

  describe JetstreamBridge::StreamCreationFailedError do
    it 'inherits from TopologyError' do
      expect(described_class).to be < JetstreamBridge::TopologyError
    end

    it 'indicates stream creation failed' do
      expect do
        raise described_class, 'Stream creation failed'
      end.to raise_error(described_class, 'Stream creation failed')
    end
  end

  describe JetstreamBridge::SubjectOverlapError do
    it 'inherits from TopologyError' do
      expect(described_class).to be < JetstreamBridge::TopologyError
    end

    it 'indicates overlapping subjects' do
      expect do
        raise described_class, 'Overlapping subjects detected'
      end.to raise_error(described_class, 'Overlapping subjects detected')
    end
  end

  describe JetstreamBridge::DlqError do
    it 'inherits from JetstreamBridge::Error' do
      expect(described_class).to be < JetstreamBridge::Error
    end

    it 'indicates DLQ operation failure' do
      expect do
        raise described_class, 'DLQ operation failed'
      end.to raise_error(described_class, 'DLQ operation failed')
    end
  end

  describe JetstreamBridge::TopologyError do
    it 'inherits from JetstreamBridge::Error' do
      expect(described_class).to be < JetstreamBridge::Error
    end

    it 'indicates topology configuration issue' do
      expect do
        raise described_class, 'Overlapping subjects detected'
      end.to raise_error(described_class, 'Overlapping subjects detected')
    end
  end

  describe 'error hierarchy' do
    it 'allows catching all gem errors with base Error class' do
      expect do
        raise JetstreamBridge::PublishError, 'publish failed'
      rescue JetstreamBridge::Error => e
        expect(e).to be_a(JetstreamBridge::PublishError)
        raise
      end.to raise_error(JetstreamBridge::Error)
    end

    it 'allows catching configuration errors specifically' do
      expect do
        raise JetstreamBridge::InvalidSubjectError, 'invalid subject'
      rescue JetstreamBridge::ConfigurationError => e
        expect(e).to be_a(JetstreamBridge::InvalidSubjectError)
        raise
      end.to raise_error(JetstreamBridge::ConfigurationError)
    end

    it 'distinguishes between configuration and runtime errors' do
      config_error = JetstreamBridge::ConfigurationError.new
      runtime_error = JetstreamBridge::PublishError.new

      expect(config_error).to be_a(JetstreamBridge::ConfigurationError)
      expect(runtime_error).not_to be_a(JetstreamBridge::ConfigurationError)
      expect(config_error).to be_a(JetstreamBridge::Error)
      expect(runtime_error).to be_a(JetstreamBridge::Error)
    end
  end
end
