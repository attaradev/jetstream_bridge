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

    it 'accepts and freezes context' do
      error = described_class.new('test', context: { key: 'value', number: 42 })
      expect(error.context).to eq({ key: 'value', number: 42 })
      expect(error.context).to be_frozen
    end

    it 'defaults to empty context' do
      error = described_class.new('test')
      expect(error.context).to eq({})
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

    it 'stores event_id and subject' do
      error = described_class.new('publish failed', event_id: 'evt-123', subject: 'test.subject')
      expect(error.event_id).to eq('evt-123')
      expect(error.subject).to eq('test.subject')
      expect(error.context).to include(event_id: 'evt-123', subject: 'test.subject')
    end

    it 'handles nil event_id and subject with compact' do
      error = described_class.new('publish failed', event_id: nil, subject: nil)
      expect(error.event_id).to be_nil
      expect(error.subject).to be_nil
      # nil values should be compacted out
      expect(error.context).to eq({})
    end

    it 'merges additional context' do
      error = described_class.new('publish failed',
                                  event_id: 'evt-123',
                                  subject: 'test.subject',
                                  context: { attempt: 2, retryable: true })
      expect(error.context).to include(event_id: 'evt-123', subject: 'test.subject', attempt: 2, retryable: true)
    end

    it 'compacts nil values in context' do
      error = described_class.new('publish failed',
                                  event_id: 'evt-123',
                                  subject: nil,
                                  context: {})
      expect(error.context).to eq({ event_id: 'evt-123' })
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

    it 'stores event_id and deliveries' do
      error = described_class.new('consumer failed', event_id: 'evt-456', deliveries: 3)
      expect(error.event_id).to eq('evt-456')
      expect(error.deliveries).to eq(3)
      expect(error.context).to include(event_id: 'evt-456', deliveries: 3)
    end

    it 'handles nil event_id and deliveries with compact' do
      error = described_class.new('consumer failed', event_id: nil, deliveries: nil)
      expect(error.event_id).to be_nil
      expect(error.deliveries).to be_nil
      expect(error.context).to eq({})
    end

    it 'merges additional context' do
      error = described_class.new('consumer failed',
                                  event_id: 'evt-456',
                                  deliveries: 2,
                                  context: { handler: 'TestHandler', queue: 'default' })
      expect(error.context).to include(event_id: 'evt-456', deliveries: 2, handler: 'TestHandler', queue: 'default')
    end
  end

  describe JetstreamBridge::BatchPublishError do
    it 'stores failed_events and successful_count' do
      failed = [{ id: 1, error: 'timeout' }, { id: 2, error: 'invalid' }]
      error = described_class.new('batch failed', failed_events: failed, successful_count: 8)
      expect(error.failed_events).to eq(failed)
      expect(error.successful_count).to eq(8)
      expect(error.context).to include(failed_count: 2, successful_count: 8)
    end

    it 'handles empty failed_events' do
      error = described_class.new('partial batch', failed_events: [], successful_count: 10)
      expect(error.failed_events).to eq([])
      expect(error.context).to include(failed_count: 0, successful_count: 10)
    end

    it 'defaults to empty array and zero count' do
      error = described_class.new('batch failed')
      expect(error.failed_events).to eq([])
      expect(error.successful_count).to eq(0)
      expect(error.context).to include(failed_count: 0, successful_count: 0)
    end
  end

  describe JetstreamBridge::RetryExhausted do
    it 'stores attempts and original_error' do
      original = StandardError.new('connection timeout')
      error = described_class.new('retry exhausted', attempts: 3, original_error: original)
      expect(error.attempts).to eq(3)
      expect(error.original_error).to eq(original)
      expect(error.context).to include(attempts: 3)
    end

    it 'generates default message from attempts and original_error' do
      original = StandardError.new('connection timeout')
      error = described_class.new(nil, attempts: 5, original_error: original)
      expect(error.message).to eq('Failed after 5 attempts: connection timeout')
    end

    it 'handles nil original_error with safe navigation' do
      error = described_class.new(nil, attempts: 3, original_error: nil)
      expect(error.message).to eq('Failed after 3 attempts: ')
    end

    it 'uses custom message when provided' do
      error = described_class.new('custom message', attempts: 3, original_error: StandardError.new('test'))
      expect(error.message).to eq('custom message')
    end

    it 'merges additional context with compact' do
      error = described_class.new('retry exhausted',
                                  attempts: 3,
                                  context: { operation: 'publish', subject: 'test.subject' })
      expect(error.context).to include(attempts: 3, operation: 'publish', subject: 'test.subject')
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
