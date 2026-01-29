# frozen_string_literal: true

require 'jetstream_bridge'
require 'active_record'
require 'oj'

RSpec.describe JetstreamBridge::OutboxEvent do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::Schema.define do
      create_table :jetstream_bridge_outbox_events, force: true do |t|
        t.string :event_id, null: false
        t.string :resource_type
        t.string :resource_id
        t.string :event_type
        t.text :payload, null: false
        t.string :subject, null: false
        t.string :status, default: 'pending'
        t.integer :attempts, default: 0
        t.text :last_error
        t.datetime :enqueued_at
        t.datetime :sent_at
        t.timestamps
      end
    end
  end

  after(:all) do
    ActiveRecord::Base.connection.disconnect!
  end

  after do
    described_class.delete_all
  end

  describe 'validations' do
    it 'validates presence of payload' do
      event = described_class.new(event_id: 'test-1', subject: 'test.subject')
      expect(event.valid?).to be false
      expect(event.errors[:payload]).to include("can't be blank")
    end

    it 'validates presence and uniqueness of event_id' do
      described_class.create!(
        event_id: 'unique-id',
        subject: 'test.subject',
        payload: { data: 'test' }.to_json,
        resource_type: 'User',
        resource_id: '123',
        event_type: 'created'
      )

      duplicate = described_class.new(
        event_id: 'unique-id',
        subject: 'test.subject',
        payload: { data: 'test2' }.to_json,
        resource_type: 'User',
        resource_id: '123',
        event_type: 'created'
      )
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:event_id]).to include('has already been taken')
    end

    it 'validates presence of subject' do
      event = described_class.new(event_id: 'test-2', payload: { data: 'test' }.to_json)
      expect(event.valid?).to be false
      expect(event.errors[:subject]).to include("can't be blank")
    end

    it 'validates attempts is an integer >= 0' do
      event = described_class.new(
        event_id: 'test-3',
        subject: 'test.subject',
        payload: { data: 'test' }.to_json,
        attempts: -1
      )
      expect(event.valid?).to be false
      expect(event.errors[:attempts]).to be_present
    end
  end

  describe 'before_validation callback' do
    it 'sets default status to pending' do
      event = described_class.new(
        event_id: 'test-4',
        subject: 'test.subject',
        payload: { data: 'test' }.to_json
      )
      event.valid?
      expect(event.status).to eq('pending')
    end

    it 'sets default enqueued_at timestamp' do
      event = described_class.new(
        event_id: 'test-5',
        subject: 'test.subject',
        payload: { data: 'test' }.to_json
      )
      event.valid?
      expect(event.enqueued_at).to be_within(1.second).of(Time.now.utc)
    end

    it 'sets default attempts to 0' do
      event = described_class.new(
        event_id: 'test-6',
        subject: 'test.subject',
        payload: { data: 'test' }.to_json
      )
      event.valid?
      expect(event.attempts).to eq(0)
    end

    it 'does not override existing status' do
      event = described_class.new(
        event_id: 'test-7',
        subject: 'test.subject',
        payload: { data: 'test' }.to_json,
        status: 'sent'
      )
      event.valid?
      expect(event.status).to eq('sent')
    end

    it 'does not override existing enqueued_at' do
      past_time = 1.hour.ago
      event = described_class.new(
        event_id: 'test-8',
        subject: 'test.subject',
        payload: { data: 'test' }.to_json,
        enqueued_at: past_time
      )
      event.valid?
      expect(event.enqueued_at).to be_within(1.second).of(past_time)
    end
  end

  describe '#mark_sent!' do
    let(:event) do
      described_class.create!(
        event_id: 'test-9',
        subject: 'test.subject',
        payload: { data: 'test' }.to_json,
        resource_type: 'User',
        resource_id: '123',
        event_type: 'created'
      )
    end

    it 'updates status to sent' do
      event.mark_sent!
      expect(event.reload.status).to eq('sent')
    end

    it 'sets sent_at timestamp' do
      event.mark_sent!
      expect(event.reload.sent_at).to be_within(1.second).of(Time.now.utc)
    end
  end

  describe '#mark_failed!' do
    let(:event) do
      described_class.create!(
        event_id: 'test-10',
        subject: 'test.subject',
        payload: { data: 'test' }.to_json,
        resource_type: 'User',
        resource_id: '123',
        event_type: 'created'
      )
    end

    it 'updates status to failed' do
      event.mark_failed!('Connection error')
      expect(event.reload.status).to eq('failed')
    end

    it 'sets last_error message' do
      error_msg = 'Timeout connecting to NATS'
      event.mark_failed!(error_msg)
      expect(event.reload.last_error).to eq(error_msg)
    end
  end

  describe '#payload_hash' do
    context 'when payload is a JSON string' do
      it 'parses and returns a hash' do
        event = described_class.create!(
          event_id: 'test-11',
          subject: 'test.subject',
          payload: '{"key":"value","nested":{"data":123}}',
          resource_type: 'User',
          resource_id: '123',
          event_type: 'created'
        )
        result = event.payload_hash
        expect(result).to eq({ 'key' => 'value', 'nested' => { 'data' => 123 } })
      end
    end

    context 'when payload is invalid JSON' do
      it 'returns empty hash' do
        event = described_class.create!(
          event_id: 'test-12',
          subject: 'test.subject',
          payload: 'not valid json {',
          resource_type: 'User',
          resource_id: '123',
          event_type: 'created'
        )
        result = event.payload_hash
        expect(result).to eq({})
      end
    end
  end

  describe '.has_column?' do
    it 'returns true for existing columns' do
      expect(described_class.has_column?(:event_id)).to be true
      expect(described_class.has_column?(:payload)).to be true
      expect(described_class.has_column?(:subject)).to be true
    end

    it 'returns false for non-existing columns' do
      expect(described_class.has_column?(:nonexistent_column)).to be false
    end

    it 'handles string column names' do
      expect(described_class.has_column?('event_id')).to be true
    end

    it 'returns false when not connected' do
      allow(described_class).to receive(:ar_connected?).and_return(false)
      expect(described_class.has_column?(:event_id)).to be false
    end

    it 'returns false when ConnectionNotEstablished is raised' do
      allow(described_class).to receive(:ar_connected?).and_return(true)
      allow(described_class.connection).to receive(:schema_cache).and_raise(ActiveRecord::ConnectionNotEstablished)
      expect(described_class.has_column?(:event_id)).to be false
    end

    it 'returns false when NoDatabaseError is raised' do
      allow(described_class).to receive(:ar_connected?).and_return(true)
      allow(described_class.connection).to receive(:schema_cache).and_raise(ActiveRecord::NoDatabaseError)
      expect(described_class.has_column?(:event_id)).to be false
    end
  end

  describe 'scopes' do
    before do
      # Create various events with different statuses
      described_class.create!(
        event_id: 'pending-1',
        subject: 'test.pending',
        payload: { data: 'pending' }.to_json,
        status: 'pending',
        resource_type: 'User',
        resource_id: '1',
        event_type: 'created'
      )
      described_class.create!(
        event_id: 'sent-1',
        subject: 'test.sent',
        payload: { data: 'sent' }.to_json,
        status: 'sent',
        sent_at: Time.now.utc,
        resource_type: 'User',
        resource_id: '2',
        event_type: 'updated'
      )
      described_class.create!(
        event_id: 'failed-1',
        subject: 'test.failed',
        payload: { data: 'failed' }.to_json,
        status: 'failed',
        last_error: 'Connection error',
        resource_type: 'Order',
        resource_id: '3',
        event_type: 'created'
      )
      described_class.create!(
        event_id: 'publishing-1',
        subject: 'test.publishing',
        payload: { data: 'publishing' }.to_json,
        status: 'publishing',
        resource_type: 'User',
        resource_id: '4',
        event_type: 'deleted'
      )
      # Create stale event
      stale_event = described_class.create!(
        event_id: 'stale-1',
        subject: 'test.stale',
        payload: { data: 'stale' }.to_json,
        status: 'pending',
        resource_type: 'User',
        resource_id: '5',
        event_type: 'created'
      )
      stale_event.update_column(:created_at, 2.hours.ago)
    end

    describe '.pending' do
      it 'returns only pending events' do
        pending_events = described_class.pending
        expect(pending_events.count).to eq(2)
        expect(pending_events.pluck(:status).uniq).to eq(['pending'])
      end
    end

    describe '.publishing' do
      it 'returns only publishing events' do
        publishing_events = described_class.publishing
        expect(publishing_events.count).to eq(1)
        expect(publishing_events.first.status).to eq('publishing')
      end
    end

    describe '.sent' do
      it 'returns only sent events' do
        sent_events = described_class.sent
        expect(sent_events.count).to eq(1)
        expect(sent_events.first.status).to eq('sent')
      end
    end

    describe '.failed' do
      it 'returns only failed events' do
        failed_events = described_class.failed
        expect(failed_events.count).to eq(1)
        expect(failed_events.first.status).to eq('failed')
      end
    end

    describe '.stale' do
      it 'returns pending events older than 1 hour' do
        stale_events = described_class.stale
        expect(stale_events.count).to eq(1)
        expect(stale_events.first.event_id).to eq('stale-1')
      end
    end

    describe '.by_resource_type' do
      it 'filters by resource type' do
        user_events = described_class.by_resource_type('User')
        expect(user_events.count).to eq(4)
        expect(user_events.pluck(:resource_type).uniq).to eq(['User'])
      end

      it 'filters by different resource type' do
        order_events = described_class.by_resource_type('Order')
        expect(order_events.count).to eq(1)
        expect(order_events.first.resource_type).to eq('Order')
      end
    end

    describe '.by_event_type' do
      it 'filters by event type' do
        created_events = described_class.by_event_type('created')
        expect(created_events.count).to eq(3)
        expect(created_events.pluck(:event_type).uniq).to eq(['created'])
      end

      it 'filters by different event type' do
        updated_events = described_class.by_event_type('updated')
        expect(updated_events.count).to eq(1)
        expect(updated_events.first.event_type).to eq('updated')
      end
    end

    describe '.recent' do
      it 'returns events ordered by created_at descending' do
        recent_events = described_class.recent(3)
        expect(recent_events.count).to eq(3)
        # Most recent should be first (stale is oldest)
        expect(recent_events.first.event_id).not_to eq('stale-1')
      end

      it 'respects the limit parameter' do
        recent_events = described_class.recent(2)
        expect(recent_events.count).to eq(2)
      end

      it 'defaults to 100 events' do
        recent_events = described_class.recent
        expect(recent_events.count).to eq(5)
      end
    end
  end

  describe 'class methods' do
    describe '.retry_failed' do
      before do
        3.times do |i|
          described_class.create!(
            event_id: "failed-#{i}",
            subject: 'test.failed',
            payload: { data: 'test' }.to_json,
            status: 'failed',
            attempts: 3,
            last_error: 'Connection timeout',
            resource_type: 'User',
            resource_id: i.to_s,
            event_type: 'created'
          )
        end
      end

      it 'resets failed events to pending' do
        count = described_class.retry_failed(limit: 2)
        expect(count).to eq(2)
        expect(described_class.pending.count).to eq(2)
        expect(described_class.failed.count).to eq(1)
      end

      it 'resets attempts to 0' do
        described_class.retry_failed(limit: 1)
        retried = described_class.pending.first
        expect(retried.attempts).to eq(0)
      end

      it 'clears last_error' do
        described_class.retry_failed(limit: 1)
        retried = described_class.pending.first
        expect(retried.last_error).to be_nil
      end

      it 'respects the limit parameter' do
        count = described_class.retry_failed(limit: 1)
        expect(count).to eq(1)
      end

      it 'defaults to 100 limit' do
        count = described_class.retry_failed
        expect(count).to eq(3)
      end
    end

    describe '.cleanup_sent' do
      before do
        # Create recent sent event
        described_class.create!(
          event_id: 'sent-recent',
          subject: 'test.sent',
          payload: { data: 'recent' }.to_json,
          status: 'sent',
          sent_at: 1.day.ago,
          resource_type: 'User',
          resource_id: '1',
          event_type: 'created'
        )
        # Create old sent events
        2.times do |i|
          old_event = described_class.create!(
            event_id: "sent-old-#{i}",
            subject: 'test.sent',
            payload: { data: 'old' }.to_json,
            status: 'sent',
            resource_type: 'User',
            resource_id: i.to_s,
            event_type: 'created'
          )
          old_event.update_column(:sent_at, 8.days.ago)
        end
      end

      it 'deletes old sent events' do
        count = described_class.cleanup_sent(older_than: 7.days)
        expect(count).to eq(2)
        expect(described_class.sent.count).to eq(1)
      end

      it 'does not delete recent sent events' do
        described_class.cleanup_sent(older_than: 7.days)
        expect(described_class.sent.pluck(:event_id)).to eq(['sent-recent'])
      end

      it 'respects the older_than parameter' do
        count = described_class.cleanup_sent(older_than: 2.days)
        expect(count).to eq(2)
      end
    end

    describe '.ar_connected?' do
      it 'returns true when connected and pool is active' do
        # Ensure we have an active connection
        ActiveRecord::Base.connection.execute('SELECT 1')
        # The method returns the connection_pool if connected
        result = described_class.ar_connected?
        expect(result).to be_truthy
      end

      it 'handles connection pool errors gracefully' do
        # This test just ensures the method doesn't raise
        expect { described_class.ar_connected? }.not_to raise_error
      end

      it 'returns false when ActiveRecord::Base is not connected' do
        allow(ActiveRecord::Base).to receive(:connected?).and_return(false)
        expect(described_class.ar_connected?).to be false
      end

      it 'returns false when connection_pool has no active connection' do
        allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
        allow(described_class.connection_pool).to receive(:active_connection?).and_return(false)
        expect(described_class.ar_connected?).to be false
      end

      it 'returns false when StandardError is raised' do
        allow(ActiveRecord::Base).to receive(:connected?).and_raise(StandardError, 'connection error')
        expect(described_class.ar_connected?).to be false
      end

      it 'returns false when connection_pool raises error' do
        original_connected = ActiveRecord::Base.method(:connected?)
        allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
        allow(described_class).to receive(:connection_pool).and_raise(StandardError, 'pool error')

        expect(described_class.ar_connected?).to be false

        # Restore original behavior for cleanup
        allow(ActiveRecord::Base).to receive(:connected?).and_wrap_original(&original_connected)
        allow(described_class).to receive(:connection_pool).and_call_original
      end
    end
  end

  describe '#retry!' do
    let(:event) do
      described_class.create!(
        event_id: 'retry-test',
        subject: 'test.retry',
        payload: { data: 'test' }.to_json,
        status: 'failed',
        attempts: 3,
        last_error: 'Timeout',
        resource_type: 'User',
        resource_id: '1',
        event_type: 'created'
      )
    end

    it 'resets status to pending' do
      event.retry!
      expect(event.reload.status).to eq('pending')
    end

    it 'resets attempts to 0' do
      event.retry!
      expect(event.reload.attempts).to eq(0)
    end

    it 'clears last_error' do
      event.retry!
      expect(event.reload.last_error).to be_nil
    end
  end

  describe '#payload_hash' do
    context 'when payload is already a Hash stored in DB' do
      it 'returns the hash directly after reload' do
        event = described_class.create!(
          event_id: 'hash-test',
          subject: 'test.hash',
          payload: { 'key' => 'value', 'nested' => { 'data' => 123 } },
          resource_type: 'Test',
          resource_id: '1',
          event_type: 'test'
        )
        # Reload to ensure we get the DB-serialized value
        event.reload
        result = event.payload_hash
        # Should return the hash (though it might be stored as JSON string in some DBs)
        expect(result).to be_a(Hash)
      end
    end

    context 'when payload is an object with as_json' do
      it 'converts object to JSON and back' do
        obj = Struct.new(:data) do
          def as_json(_options = {})
            { 'converted' => 'data', 'value' => data }
          end

          def to_json(*_args)
            as_json.to_json
          end
        end.new('test')

        # ActiveRecord will serialize this via to_json
        event = described_class.create!(
          event_id: 'obj-test',
          subject: 'test.obj',
          payload: obj.to_json, # Store as JSON string
          resource_type: 'Test',
          resource_id: '1',
          event_type: 'test'
        )
        event.reload
        result = event.payload_hash
        expect(result).to include('converted' => 'data')
      end
    end
  end

  describe 'without ActiveRecord (shim class)' do
    # Test the shim class behavior by creating a standalone test class
    before(:all) do
      @shim_class = Class.new do
        class << self
          def method_missing(method_name, *_args, &)
            raise(
              "Outbox requires ActiveRecord (tried to call ##{method_name}). " \
              'Enable `use_outbox` only in apps with ActiveRecord, or add ' \
              '`gem "activerecord"` to your Gemfile.'
            )
          end

          def respond_to_missing?(_method_name, _include_private = false)
            false
          end
        end
      end
    end

    it 'raises helpful error when calling class methods without ActiveRecord' do
      expect do
        @shim_class.create
      end.to raise_error(/Outbox requires ActiveRecord.*tried to call #create/)

      expect do
        @shim_class.find(1)
      end.to raise_error(/Outbox requires ActiveRecord.*tried to call #find/)
    end

    it 'mentions gem installation in error message' do
      expect do
        @shim_class.all
      end.to raise_error(/gem "activerecord"/)
    end

    it 'returns false for respond_to_missing?' do
      expect(@shim_class.respond_to?(:create, true)).to be false
      expect(@shim_class.respond_to?(:find, true)).to be false
    end
  end
end
