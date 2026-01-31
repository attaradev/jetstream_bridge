# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::Connection do
  let(:conn) { described_class.instance }
  let(:original_nc) { conn.instance_variable_get(:@nc) }
  let(:original_jts) { conn.instance_variable_get(:@jts) }

  after do
    conn.instance_variable_set(:@nc, original_nc)
    conn.instance_variable_set(:@jts, original_jts)
    conn.instance_variable_set(:@cached_health_status, nil)
    conn.instance_variable_set(:@last_health_check, nil)
    conn.instance_variable_set(:@state, nil)
    conn.instance_variable_set(:@reconnecting, nil)
    conn.instance_variable_set(:@last_reconnect_error, nil)
    conn.instance_variable_set(:@last_reconnect_error_at, nil)
  end

  describe '#ping_only_health' do
    it 'returns true when nc is connected and flush succeeds' do
      nc = instance_double('NATS::IO::Client', connected?: true, flush: true)
      conn.instance_variable_set(:@nc, nc)

      expect(conn.send(:ping_only_health)).to be true
    end

    it 'returns false and logs when flush fails' do
      nc = instance_double('NATS::IO::Client', connected?: true)
      allow(nc).to receive(:flush).and_raise(StandardError.new('boom'))
      conn.instance_variable_set(:@nc, nc)
      expect(JetstreamBridge::Logging).to receive(:warn)

      expect(conn.send(:ping_only_health)).to be false
    end

    it 'returns false when nc is nil' do
      conn.instance_variable_set(:@nc, nil)
      expect(conn.send(:ping_only_health)).to be false
    end
  end

  describe '#jetstream_healthy?' do
    it 'returns true when account_info succeeds' do
      jts = instance_double('JetStream', account_info: true)
      conn.instance_variable_set(:@jts, jts)

      expect(conn.send(:jetstream_healthy?, verify_js: true)).to be true
    end

    it 'returns true when verify_js is false and nc is connected' do
      nc = instance_double('NATS::IO::Client', connected?: true, flush: true)
      conn.instance_variable_set(:@nc, nc)

      expect(conn.send(:jetstream_healthy?, verify_js: false)).to be true
    end

    it 'returns false and logs when account_info fails' do
      jts = instance_double('JetStream')
      allow(jts).to receive(:account_info).and_raise(StandardError.new('fail'))
      conn.instance_variable_set(:@jts, jts)
      expect(JetstreamBridge::Logging).to receive(:warn)

      expect(conn.send(:jetstream_healthy?, verify_js: true)).to be false
    end

    it 'returns false when verify_js is false and nc not connected' do
      nc = instance_double('NATS::IO::Client', connected?: false)
      conn.instance_variable_set(:@nc, nc)

      expect(conn.send(:jetstream_healthy?, verify_js: false)).to be false
    end
  end

  describe '#connected?' do
    it 'returns false when nc not connected' do
      conn.instance_variable_set(:@nc, instance_double('NATS::IO::Client', connected?: false))
      expect(conn.connected?).to be false
    end

    it 'returns cached value when fresh' do
      conn.instance_variable_set(:@nc, instance_double('NATS::IO::Client', connected?: true))
      conn.instance_variable_set(:@jts, double(:js))
      conn.instance_variable_set(:@cached_health_status, true)
      conn.instance_variable_set(:@last_health_check, Time.now.to_i)

      expect(conn.connected?).to be true
    end
  end

  describe '#state' do
    it 'returns :failed when last_reconnect_error present and nc disconnected' do
      nc = instance_double('NATS::IO::Client', connected?: false)
      conn.instance_variable_set(:@nc, nc)
      conn.instance_variable_set(:@last_reconnect_error, StandardError.new('boom'))
      expect(conn.state).to eq(JetstreamBridge::Connection::State::FAILED)
    end
  end
end
