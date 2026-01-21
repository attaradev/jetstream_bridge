# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::Topology do
  let(:mock_jts) { double('NATS::JetStream') }
  let(:config) do
    JetstreamBridge::Config.new.tap do |c|
      c.nats_urls = 'nats://localhost:4222'
      c.destination_app = 'dest_app'
      c.app_name = 'test_app'
      c.env = 'development'
      c.stream_name = 'test_app-jetstream-bridge-stream'
    end
  end

  before do
    allow(JetstreamBridge).to receive(:config).and_return(config)
  end

  describe '.ensure!' do
    before do
      allow(JetstreamBridge::Stream).to receive(:ensure!)
    end

    it 'ensures stream with source and destination subjects' do
      expect(JetstreamBridge::Stream).to receive(:ensure!).with(
        mock_jts,
        'test_app-jetstream-bridge-stream',
        array_including(
          'test_app.sync.dest_app',
          'dest_app.sync.test_app'
        )
      )
      described_class.ensure!(mock_jts, force: true)
    end

    context 'when DLQ is enabled' do
      before do
        allow(config).to receive(:use_dlq).and_return(true)
      end

      it 'includes DLQ subject' do
        expect(JetstreamBridge::Stream).to receive(:ensure!).with(
        mock_jts,
        'test_app-jetstream-bridge-stream',
        array_including(
          'test_app.sync.dest_app',
          'dest_app.sync.test_app',
          'test_app.sync.dlq'
        )
      )
      described_class.ensure!(mock_jts, force: true)
    end
    end

    context 'when DLQ is disabled' do
      before do
        allow(config).to receive(:use_dlq).and_return(false)
      end

      it 'does not include DLQ subject' do
        expect(JetstreamBridge::Stream).to receive(:ensure!).with(
          mock_jts,
          anything,
          array_excluding('test_app.sync.dlq')
        )
        described_class.ensure!(mock_jts, force: true)
      end
    end

    it 'uses stream name from config' do
      expect(JetstreamBridge::Stream).to receive(:ensure!).with(
        mock_jts,
        'test_app-jetstream-bridge-stream',
        anything
      )
      described_class.ensure!(mock_jts, force: true)
    end

    it 'uses source subject from config' do
      expect(JetstreamBridge::Stream).to receive(:ensure!).with(
        mock_jts,
        anything,
        array_including('test_app.sync.dest_app')
      )
      described_class.ensure!(mock_jts, force: true)
    end

    it 'uses destination subject from config' do
      expect(JetstreamBridge::Stream).to receive(:ensure!).with(
        mock_jts,
        anything,
        array_including('dest_app.sync.test_app')
      )
      described_class.ensure!(mock_jts, force: true)
    end
  end
end
