# frozen_string_literal: true

require 'jetstream_bridge'
require 'logger'
require 'stringio'

RSpec.describe JetstreamBridge::Logging do
  after { JetstreamBridge.reset! }

  describe '.logger' do
    it 'uses configured logger' do
      io = StringIO.new
      custom_logger = Logger.new(io)
      JetstreamBridge.configure(logger: custom_logger)

      described_class.info('hello', tag: 'Spec')

      io.rewind
      expect(io.string).to include('[Spec] hello')
    end

    it 'falls back to default logger when no logger configured' do
      JetstreamBridge.reset!
      logger = described_class.logger
      expect(logger).to be_a(Logger)
    end
  end

  describe 'log methods' do
    let(:io) { StringIO.new }
    let(:custom_logger) { Logger.new(io) }

    before do
      JetstreamBridge.configure(logger: custom_logger)
    end

    it 'logs debug messages with tag' do
      described_class.debug('dbg', tag: 'Spec')
      io.rewind
      expect(io.string).to include('[Spec] dbg')
    end

    it 'logs debug messages without tag' do
      described_class.debug('dbg')
      io.rewind
      expect(io.string).to include('dbg')
      expect(io.string).not_to include('[Spec]')
    end

    it 'logs info messages with tag' do
      described_class.info('information', tag: 'Spec')
      io.rewind
      expect(io.string).to include('[Spec] information')
    end

    it 'logs warn messages with tag' do
      described_class.warn('warning', tag: 'Spec')
      io.rewind
      expect(io.string).to include('[Spec] warning')
    end

    it 'logs error messages with tag' do
      described_class.error('error', tag: 'Spec')
      io.rewind
      expect(io.string).to include('[Spec] error')
    end
  end

  describe '.sanitize_url' do
    context 'when URL has username and password' do
      it 'masks password but keeps username' do
        url = 'nats://user:secret@example.com:4222/path'
        result = described_class.sanitize_url(url)
        expect(result).to eq('nats://user:***@example.com:4222/path')
        expect(result).not_to include('secret')
      end

      it 'handles URLs with fragment' do
        url = 'nats://user:pass@example.com:4222/path#fragment'
        result = described_class.sanitize_url(url)
        expect(result).to eq('nats://user:***@example.com:4222/path#fragment')
      end
    end

    context 'when URL has token-only auth' do
      it 'masks entire userinfo' do
        url = 'nats://token@example.com:4222'
        result = described_class.sanitize_url(url)
        expect(result).to eq('nats://***@example.com:4222')
      end
    end

    context 'when URL has no credentials' do
      it 'returns URL unchanged' do
        url = 'nats://example.com:4222/path'
        result = described_class.sanitize_url(url)
        expect(result).to eq(url)
      end
    end

    context 'when URL has no port' do
      it 'omits port from output' do
        url = 'nats://user:pass@example.com/path'
        result = described_class.sanitize_url(url)
        expect(result).to eq('nats://user:***@example.com/path')
      end
    end

    context 'when URL is invalid' do
      it 'falls back to regex replacement for nats scheme' do
        url = 'nats://invalid url with:password@example.com'
        result = described_class.sanitize_url(url)
        expect(result).to include('***')
      end

      it 'handles credentials with colon in fallback' do
        url = 'nats://user:secret@host'
        # Force invalid URI error path
        allow(URI).to receive(:parse).and_raise(URI::InvalidURIError)
        result = described_class.sanitize_url(url)
        expect(result).to eq('nats://user:***@host')
      end

      it 'handles token-only credentials in fallback' do
        url = 'tls://token@host'
        allow(URI).to receive(:parse).and_raise(URI::InvalidURIError)
        result = described_class.sanitize_url(url)
        expect(result).to eq('tls://***@host')
      end
    end

    context 'when URL has query string' do
      it 'omits query string to avoid leaking tokens' do
        url = 'nats://user:pass@example.com:4222/path?token=secret'
        result = described_class.sanitize_url(url)
        expect(result).to eq('nats://user:***@example.com:4222/path')
        expect(result).not_to include('token=secret')
      end
    end
  end
end
