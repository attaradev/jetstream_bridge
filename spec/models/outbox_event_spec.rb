# frozen_string_literal: true

require 'jetstream_bridge'
require 'active_record'
require 'oj'

RSpec.describe JetstreamBridge::OutboxEvent do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::Schema.define do
      create_table :jetstream_outbox_events, force: true do |t|
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
        payload: { data: 'test' }.to_json
      )

      duplicate = described_class.new(
        event_id: 'unique-id',
        subject: 'test.subject',
        payload: { data: 'test2' }.to_json
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
        payload: { data: 'test' }.to_json
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
        payload: { data: 'test' }.to_json
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
          payload: '{"key":"value","nested":{"data":123}}'
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
      expect(described_class.has_column?(:payload)).to be true
      expect(described_class.has_column?(:subject)).to be true
    end

    it 'returns false for non-existing columns' do
      expect(described_class.has_column?(:nonexistent_column)).to be false
    end

    it 'handles string column names' do
      expect(described_class.has_column?('event_id')).to be true
    end
  end
end
