# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge/core/debug_helper'

RSpec.describe JetstreamBridge::DebugHelper do
  let(:config) do
    JetstreamBridge::Config.new.tap do |c|
      c.nats_urls = 'nats://localhost:4222'
      c.destination_app = 'dest_app'
      c.app_name = 'app'
      c.stream_name = 'app-jetstream-bridge-stream'
      c.disable_js_api = false
    end
  end

  let(:mock_connection) do
    double('Connection',
           connected?: true,
           connected_at: Time.utc(2024, 1, 1, 12, 0, 0),
           instance_variable_get: true)
  end

  before do
    allow(JetstreamBridge).to receive(:config).and_return(config)
    allow(JetstreamBridge::Connection).to receive(:instance).and_return(mock_connection)
    allow(JetstreamBridge::Logging).to receive(:info)
  end

  describe '.debug_info' do
    let(:mock_stream_info) do
      double('StreamInfo',
             config: double('Config',
                            subjects: ['test.*'],
                            retention: 'limits',
                            storage: 'file',
                            max_consumers: -1),
             state: double('State',
                           messages: 100,
                           bytes: 1024,
                           first_seq: 1,
                           last_seq: 100))
    end

    let(:mock_jts) { double('JetStream') }

    before do
      allow(JetstreamBridge).to receive(:health_check).and_return({ healthy: true })
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(mock_jts)
      allow(mock_jts).to receive(:stream_info).and_return(mock_stream_info)
    end

    it 'returns debug information hash' do
      result = described_class.debug_info
      expect(result).to be_a(Hash)
      expect(result).to have_key(:config)
      expect(result).to have_key(:connection)
      expect(result).to have_key(:stream)
      expect(result).to have_key(:health)
    end

    it 'logs debug header' do
      expect(JetstreamBridge::Logging).to receive(:info).with(
        '=== JetStream Bridge Debug Info ===',
        tag: 'JetstreamBridge::Debug'
      )
      described_class.debug_info
    end

    it 'logs section headers' do
      expect(JetstreamBridge::Logging).to receive(:info).with(
        'CONFIG:',
        tag: 'JetstreamBridge::Debug'
      )
      expect(JetstreamBridge::Logging).to receive(:info).with(
        'CONNECTION:',
        tag: 'JetstreamBridge::Debug'
      )
      described_class.debug_info
    end

    it 'logs debug footer' do
      expect(JetstreamBridge::Logging).to receive(:info).with(
        '=== End Debug Info ===',
        tag: 'JetstreamBridge::Debug'
      )
      described_class.debug_info
    end

    it 'includes health check results' do
      result = described_class.debug_info
      expect(result[:health]).to eq({ healthy: true })
    end
  end

  describe '.config_debug' do
    it 'returns configuration hash' do
      result = described_class.send(:config_debug)
      expect(result).to be_a(Hash)
      expect(result[:app_name]).to eq('app')
      expect(result[:destination_app]).to eq('dest_app')
    end

    it 'includes stream name' do
      result = described_class.send(:config_debug)
      expect(result[:stream_name]).to eq('app-jetstream-bridge-stream')
    end

    it 'includes nats urls' do
      result = described_class.send(:config_debug)
      expect(result[:nats_urls]).to eq('nats://localhost:4222')
    end

    it 'includes outbox/inbox settings' do
      result = described_class.send(:config_debug)
      expect(result).to have_key(:use_outbox)
      expect(result).to have_key(:use_inbox)
      expect(result).to have_key(:use_dlq)
    end

    context 'when subject methods raise errors' do
      before do
        allow(config).to receive(:source_subject).and_raise(StandardError)
        allow(config).to receive(:destination_subject).and_raise(StandardError)
        allow(config).to receive(:dlq_subject).and_raise(StandardError)
      end

      it 'returns ERROR for failing subjects' do
        result = described_class.send(:config_debug)
        expect(result[:source_subject]).to eq('ERROR')
        expect(result[:destination_subject]).to eq('ERROR')
        expect(result[:dlq_subject]).to eq('ERROR')
      end
    end
  end

  describe '.connection_debug' do
    it 'returns connection status' do
      result = described_class.send(:connection_debug)
      expect(result).to be_a(Hash)
      expect(result[:connected]).to be true
    end

    it 'includes connected_at timestamp' do
      result = described_class.send(:connection_debug)
      expect(result[:connected_at]).to eq('2024-01-01T12:00:00Z')
    end

    it 'checks for nc presence' do
      result = described_class.send(:connection_debug)
      expect(result[:nc_present]).to be true
    end

    it 'checks for jts presence' do
      result = described_class.send(:connection_debug)
      expect(result[:jts_present]).to be true
    end

    context 'when connection raises error' do
      before do
        allow(JetstreamBridge::Connection).to receive(:instance).and_raise(StandardError, 'Connection failed')
      end

      it 'returns error hash' do
        result = described_class.send(:connection_debug)
        expect(result[:error]).to eq('StandardError: Connection failed')
      end
    end
  end

  describe '.stream_debug' do
    let(:mock_stream_info) do
      double('StreamInfo',
             config: double('Config',
                            subjects: ['development.test.*'],
                            retention: 'limits',
                            storage: 'file',
                            max_consumers: 10),
             state: double('State',
                           messages: 42,
                           bytes: 2048,
                           first_seq: 5,
                           last_seq: 46))
    end

    let(:mock_jts) { double('JetStream') }

    before do
      allow(JetstreamBridge::Connection).to receive(:jetstream).and_return(mock_jts)
      allow(mock_jts).to receive(:stream_info).and_return(mock_stream_info)
    end

    context 'when connected' do
      it 'returns stream information' do
        result = described_class.send(:stream_debug)
        expect(result[:name]).to eq('app-jetstream-bridge-stream')
        expect(result[:exists]).to be true
        expect(result[:subjects]).to eq(['development.test.*'])
      end

      it 'includes stream config' do
        result = described_class.send(:stream_debug)
        expect(result[:retention]).to eq('limits')
        expect(result[:storage]).to eq('file')
        expect(result[:max_consumers]).to eq(10)
      end

      it 'includes stream state' do
        result = described_class.send(:stream_debug)
        expect(result[:messages]).to eq(42)
        expect(result[:bytes]).to eq(2048)
        expect(result[:first_seq]).to eq(5)
        expect(result[:last_seq]).to eq(46)
      end
    end

    context 'when not connected' do
      before do
        allow(mock_connection).to receive(:connected?).and_return(false)
      end

      it 'returns error hash' do
        result = described_class.send(:stream_debug)
        expect(result[:error]).to eq('Not connected')
      end
    end

    context 'when stream_info raises error' do
      before do
        allow(mock_jts).to receive(:stream_info).and_raise(StandardError, 'Stream not found')
      end

      it 'returns error with stream name' do
        result = described_class.send(:stream_debug)
        expect(result[:name]).to eq('app-jetstream-bridge-stream')
        expect(result[:exists]).to be false
        expect(result[:error]).to eq('StandardError: Stream not found')
      end
    end
  end

  describe '.log_hash' do
    it 'logs simple key-value pairs' do
      expect(JetstreamBridge::Logging).to receive(:info).with(
        '  key: value',
        tag: 'JetstreamBridge::Debug'
      )
      described_class.send(:log_hash, { key: 'value' }, indent: 2)
    end

    it 'logs nested hashes' do
      expect(JetstreamBridge::Logging).to receive(:info).with(
        '  outer:',
        tag: 'JetstreamBridge::Debug'
      )
      expect(JetstreamBridge::Logging).to receive(:info).with(
        '    inner: value',
        tag: 'JetstreamBridge::Debug'
      )
      described_class.send(:log_hash, { outer: { inner: 'value' } }, indent: 2)
    end

    it 'logs arrays with inspect' do
      expect(JetstreamBridge::Logging).to receive(:info).with(
        '  items: [1, 2, 3]',
        tag: 'JetstreamBridge::Debug'
      )
      described_class.send(:log_hash, { items: [1, 2, 3] }, indent: 2)
    end

    it 'handles zero indent' do
      expect(JetstreamBridge::Logging).to receive(:info).with(
        'key: value',
        tag: 'JetstreamBridge::Debug'
      )
      described_class.send(:log_hash, { key: 'value' }, indent: 0)
    end

    it 'logs multiple keys' do
      expect(JetstreamBridge::Logging).to receive(:info).with(
        'key1: value1',
        tag: 'JetstreamBridge::Debug'
      )
      expect(JetstreamBridge::Logging).to receive(:info).with(
        'key2: value2',
        tag: 'JetstreamBridge::Debug'
      )
      described_class.send(:log_hash, { key1: 'value1', key2: 'value2' }, indent: 0)
    end
  end
end
