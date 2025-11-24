# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge/test_helpers'
require 'oj'

RSpec.describe 'JetstreamBridge::TestHelpers utilities' do
  include JetstreamBridge::TestHelpers
  include JetstreamBridge::TestHelpers::Matchers
  include JetstreamBridge::TestHelpers::IntegrationHelpers

  before do
    JetstreamBridge::TestHelpers.enable_test_mode!
  end

  after do
    JetstreamBridge::TestHelpers.reset_test_mode!
  end

  describe JetstreamBridge::TestHelpers::Matchers do
    it 'matches published events with payload attributes' do
      JetstreamBridge::TestHelpers.record_published_event(
        { 'event_type' => 'user.created', 'payload' => { 'id' => 1, 'name' => 'Ada' } }
      )

      expect(JetstreamBridge).to have_published(event_type: 'user.created', payload: { id: 1 })
    end

    it 'checks publish success and failure results' do
      success = instance_double('Result', success?: true, failure?: false)
      failure = instance_double('Result', success?: false, failure?: true)

      expect(success).to be_publish_success
      expect(failure).to be_publish_failure
    end
  end

  describe JetstreamBridge::TestHelpers::Fixtures do
    it 'builds canned events with overrides' do
      event = JetstreamBridge::TestHelpers::Fixtures.user_created_event(id: 99, payload: { role: 'admin' })

      expect(event).to be_a(JetstreamBridge::Models::Event)
      expect(event.payload['id']).to eq(99)
      expect(event.payload['role']).to eq('admin')
    end
  end

  describe JetstreamBridge::TestHelpers::IntegrationHelpers do
    let(:storage) { JetstreamBridge::TestHelpers.mock_storage }

    it 'waits for messages and consumes them' do
      allow(JetstreamBridge::Models::Event).to receive(:from_nats_message).and_return(
        instance_double(JetstreamBridge::Models::Event, to_h: { 'event_id' => 'msg-1' })
      )

      storage.messages << {
        subject: 'test.subject',
        data: Oj.dump(event_type: 'user.created', payload: { id: 1 }),
        header: { 'nats-msg-id' => 'msg-1' },
        sequence: 1,
        delivery_count: 1
      }

      expect(wait_for_messages(1, timeout: 0.1)).to be(true)
      consumed = consume_events(batch_size: 1)
      expect(consumed.first['event_id']).to eq('msg-1')
    end

    it 'publishes and waits for mock storage' do
      allow(JetstreamBridge).to receive(:publish).and_return(
        instance_double(JetstreamBridge::Models::PublishResult, event_id: 'abc-123')
      )
      storage.messages << { header: { 'nats-msg-id' => 'abc-123' } }

      result = publish_and_wait(event_type: 'user.created', payload: { id: 1 }, timeout: 0.1)
      expect(result.event_id).to eq('abc-123')
    end
  end
end
