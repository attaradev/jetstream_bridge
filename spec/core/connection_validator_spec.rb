# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::ConnectionValidator do
  let(:validator) { described_class.new }

  describe '#validate_servers!' do
    it 'validates valid single NATS URL' do
      result = validator.validate_servers!('nats://localhost:4222')

      expect(result).to eq(['nats://localhost:4222'])
    end

    it 'validates multiple comma-separated URLs' do
      urls = 'nats://server1:4222, nats://server2:4222'
      result = validator.validate_servers!(urls)

      expect(result).to eq(['nats://server1:4222', 'nats://server2:4222'])
    end

    it 'accepts nats+tls scheme' do
      result = validator.validate_servers!('nats+tls://secure.example.com:4222')

      expect(result).to eq(['nats+tls://secure.example.com:4222'])
    end

    it 'raises error for empty URLs' do
      expect {
        validator.validate_servers!('')
      }.to raise_error(JetstreamBridge::ConnectionError, /No NATS URLs/)
    end

    it 'raises error for missing scheme' do
      expect {
        validator.validate_servers!('localhost:4222')
      }.to raise_error(JetstreamBridge::ConnectionError, /Invalid NATS URL format/)
    end

    it 'raises error for invalid scheme' do
      expect {
        validator.validate_servers!('http://localhost:4222')
      }.to raise_error(JetstreamBridge::ConnectionError, /Invalid NATS URL scheme/)
    end

    it 'raises error for missing host' do
      expect {
        validator.validate_servers!('nats://:4222')
      }.to raise_error(JetstreamBridge::ConnectionError, /missing host/)
    end

    it 'raises error for invalid port' do
      expect {
        validator.validate_servers!('nats://localhost:99999')
      }.to raise_error(JetstreamBridge::ConnectionError, /port must be 1-65535/)
    end

    it 'handles malformed URLs' do
      expect {
        validator.validate_servers!('nats://[invalid')
      }.to raise_error(JetstreamBridge::ConnectionError, /Invalid NATS URL format/)
    end
  end
end
