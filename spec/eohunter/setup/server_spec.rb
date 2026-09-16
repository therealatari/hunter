# frozen_string_literal: true

require 'spec_helper'
require 'net/http'
require_relative '../../../scripts/eohunter/setup/server'

RSpec.describe EO::HunterSetup::Server do
  let(:calls) { [] }
  let(:app) { ->(request) { calls << request; { saved: true } } }
  let(:server) { described_class.new(app: app, assets: { 'index.html' => '<h1>Setup</h1>', 'app.js' => '', 'style.css' => '' }) }

  before { server.start }
  after { server.shutdown }

  def request(path: '/api', method: Net::HTTP::Post, token: true, origin: true, body: '{"action":"bootstrap"}')
    uri = URI(server.url)
    req = method.new(path)
    req['Host'] = "127.0.0.1:#{uri.port}"
    req['Origin'] = origin == true ? "http://127.0.0.1:#{uri.port}" : origin if origin
    req['X-Setup-Token'] = uri.fragment.delete_prefix('token=') if token
    req['Content-Type'] = 'application/json'
    req.body = body if method == Net::HTTP::Post
    Net::HTTP.start(uri.host, uri.port, nil, nil, nil, nil, read_timeout: 3) { |http| http.request(req) }
  end

  it 'serves only known local assets and disallows framing/remote scripts' do
    response = request(path: '/', method: Net::HTTP::Get)
    expect(response.code).to eq('200')
    expect(response.body).to include('Setup')
    expect(response['content-security-policy']).to include("frame-ancestors 'none'", "script-src 'self'")
    expect(response['cache-control']).to eq('no-store')
    expect(request(path: '/secret.yaml', method: Net::HTTP::Get).code).to eq('404')
  end

  it 'requires same-origin authenticated JSON before invoking app' do
    expect(request(token: false).code).to eq('403')
    expect(request(origin: false).code).to eq('403')
    expect(request(origin: 'https://unrelated.example').code).to eq('403')
    expect(calls).to be_empty
    expect(request.code).to eq('200')
    expect(calls).to eq([{ 'action' => 'bootstrap' }])
  end

  it 'rejects rebinding hosts and API GET without invoking app' do
    uri = URI(server.url)
    req = Net::HTTP::Get.new('/')
    req['Host'] = 'attacker.example'
    response = Net::HTTP.start(uri.host, uri.port, nil, nil, nil, nil) { |http| http.request(req) }
    expect(response.code).to eq('403')
    expect(request(method: Net::HTTP::Get).code).to eq('405')
    expect(calls).to be_empty
  end

  it 'rejects oversized or malformed payloads without invoking app' do
    expect(request(body: 'x' * (described_class::MAX_BODY + 1)).code).to eq('413')
    expect(request(body: 'not JSON').code).to eq('422')
    expect(calls).to be_empty
  end
end
