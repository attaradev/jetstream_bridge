# frozen_string_literal: true

require 'jetstream_bridge'
require 'active_record'
require 'oj'

RSpec.describe JetstreamBridge::InboxEvent do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::Schema.define do
      create_table :jetstream_inbox_events, force: true do |t|
        t.string :event_id
        t.integer :stream_seq
        t.string :stream
        t.string :subject
        t.text :payload
        t.string :status, default: 'received'
        t.datetime :received_at
        t.datetime :processed_at
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
    context 'with event_id column present' do
      it 'validates presence of event_id' do
        event = described_class.new(subject: 'test.subject')
        expect(event.valid?).to be false
        expect(event.errors[:event_id]).to include("can't be blank")
      end

      it 'validates uniqueness of event_id' do
        described_class.create!(event_id: 'unique-id', subject: 'test.subject')
        duplicate = described_class.new(event_id: 'unique-id', subject: 'test.subject')
        expect(duplicate.valid?).to be false
        expect(duplicate.errors[:event_id]).to include('has already been taken')
      end
    end

    it 'validates presence of subject' do
      event = described_class.new(event_id: 'test-1')
      expect(event.valid?).to be false
      expect(event.errors[:subject]).to include("can't be blank")
    end
  end

  describe 'before_validation callback' do
    it 'sets default status to received' do
      event = described_class.new(event_id: 'test-2', subject: 'test.subject')
      event.valid?
      expect(event.status).to eq('received')
    end

    it 'sets default received_at timestamp' do
      event = described_class.new(event_id: 'test-3', subject: 'test.subject')
      event.valid?
      expect(event.received_at).to be_within(1.second).of(Time.now.utc)
    end

    it 'does not override existing status' do
      event = described_class.new(event_id: 'test-4', subject: 'test.subject', status: 'processed')
      event.valid?
      expect(event.status).to eq('processed')
    end

    it 'does not override existing received_at' do
      past_time = 1.hour.ago
      event = described_class.new(event_id: 'test-5', subject: 'test.subject', received_at: past_time)
      event.valid?
      expect(event.received_at).to be_within(1.second).of(past_time)
    end
  end

  describe '#processed?' do
    context 'when processed_at column exists and is set' do
      it 'returns true' do
        event = described_class.create!(
          event_id: 'test-6',
          subject: 'test.subject',
          processed_at: Time.now.utc
        )
        expect(event.processed?).to be true
      end
    end

    context 'when processed_at column exists but is nil' do
      it 'returns false even if status is processed' do
        # processed_at takes precedence when the column exists
        event = described_class.create!(
          event_id: 'test-7',
          subject: 'test.subject',
          status: 'processed',
          processed_at: nil
        )
        expect(event.processed?).to be false
      end
    end

    context 'when status is received' do
      it 'returns false' do
        event = described_class.create!(
          event_id: 'test-9',
          subject: 'test.subject',
          status: 'received'
        )
        expect(event.processed?).to be false
      end
    end
  end

  describe '#payload_hash' do
    context 'when payload is a JSON string' do
      it 'parses and returns a hash' do
        event = described_class.create!(
          event_id: 'test-10',
          subject: 'test.subject',
          payload: '{"key":"value","nested":{"data":123}}'
        )
        result = event.payload_hash
        expect(result).to eq({ 'key' => 'value', 'nested' => { 'data' => 123 } })
      end
    end

    context 'when payload is invalid JSON' do
      it 'returns empty hash' do
        event = described_class.create!(
          event_id: 'test-11',
          subject: 'test.subject',
          payload: 'not valid json {'
        )
        result = event.payload_hash
        expect(result).to eq({})
      end
    end
  end

  describe '.has_column?' do
    it 'returns true for existing columns' do
      expect(described_class.has_column?(:event_id)).to be true
      expect(described_class.has_column?(:subject)).to be true
      expect(described_class.has_column?(:stream_seq)).to be true
    end

    it 'returns false for non-existing columns' do
      expect(described_class.has_column?(:nonexistent_column)).to be false
    end

    it 'handles string column names' do
      expect(described_class.has_column?('event_id')).to be true
    end
  end
end
