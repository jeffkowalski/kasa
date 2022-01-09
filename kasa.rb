#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'json'
require 'influxdb'
require 'socket'

# see https://github.com/python-kasa/python-kasa

LOGFILE = File.join(Dir.home, '.log', 'kasa.log')

module Kernel
  def with_rescue(exceptions, logger, retries: 5)
    try = 0
    begin
      yield try
    rescue *exceptions => e
      try += 1
      raise if try > retries

      logger.info "caught error #{e.class}, retrying (#{try}/#{retries})..."
      retry
    end
  end
end


class TPLinkSmartHomeProtocol
  INITIALIZATION_VECTOR = 171

  def self.xor_payload(unencrypted)
    key = INITIALIZATION_VECTOR
    unencrypted.chars.map do |ch|
      key = key ^ ch.ord
    end
  end

  def self.encrypt(request)
    #
    # Encrypt a request for a TP-Link Smart Home Device.
    # :param request: plaintext request data
    # :return: ciphertext to be send over wire, in bytes
    #
    plainbytes = request.encode
    len = plainbytes.length
    xor_payload(plainbytes).pack("C#{len}")
  end

  def self.xor_encrypted_payload(ciphertext)
    key = INITIALIZATION_VECTOR
    ciphertext.chars.map do |cipherbyte|
      plainbyte = key ^ cipherbyte.ord
      key = cipherbyte.ord
      plainbyte.chr
    end
  end

  def self.decrypt(ciphertext)
    #
    # Decrypt a response of a TP-Link Smart Home Device.
    # :param ciphertext: encrypted response data
    # :return: plaintext response
    #
    xor_encrypted_payload(ciphertext).join('')
  end
end

class Kasa < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new $stdout
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  UDP_PORT = 9999
  DISCOVERY_QUERY = { 'system': { 'get_sysinfo': nil },
                      'time':   { 'get_time': nil },
                      'emeter': { 'get_realtime': nil } }.freeze

  desc 'record-status', 'record the current usage data to database'
  method_option :dry_run, type: :boolean, aliases: '-n', desc: "don't log to database"
  def record_status
    setup_logger

    influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'kasa')

    udpsock = UDPSocket.new
    begin
      udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_BROADCAST, true
      udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true

      @logger.info "sending broadcast to <broadcast> on port #{UDP_PORT}"
      req = DISCOVERY_QUERY.to_json
      @logger.debug req
      encrypted_req = TPLinkSmartHomeProtocol.encrypt(req)
      @logger.debug encrypted_req
      udpsock.send encrypted_req, 0, '<broadcast>', UDP_PORT

      data = []

      start = Time.now
      while Time.now < (start + 3)
        message, info = udpsock.recvfrom_nonblock(1024, exception: false)
        next if info.nil?

        device = JSON.parse(TPLinkSmartHomeProtocol.decrypt(message))

        @logger.debug device

        get_time = device['time']['get_time']
        timestamp = Time.new(get_time['year'], get_time['month'], get_time['mday'], get_time['hour'], get_time['min'], get_time['sec']).to_i

        if device['system']['get_sysinfo']['children'] # e.g. KP200
          device['system']['get_sysinfo']['children'].each do |child|
            name = child['alias']
            state = child['state']
            @logger.info "device '#{name}' state = #{state}"

            data.push({ series:    'status',
                        values:    { value: state },
                        tags:      { alias: name },
                        timestamp: timestamp })
          end
        else
          name = device['system']['get_sysinfo']['alias']
          state = device['system']['get_sysinfo']['relay_state']
          @logger.info "device '#{name}' state = #{state}"

          data.push({ series:    'status',
                      values:    { value: state },
                      tags:      { alias: name },
                      timestamp: timestamp })

          unless (!device['emeter'].key?('get_realtime') || device['emeter']['get_realtime']['err_code'] != 0)
            power = device['emeter']['get_realtime']['power'].to_f
            @logger.info "device '#{name}' power = #{power}"
            data.push({ series:    'power',
                        values:    { value: power },
                        tags:      { alias: name },
                        timestamp: timestamp })
          end
        end
      end

      influxdb.write_points data unless options[:dry_run]
    rescue StandardError => e
      @logger.error "caught exception #{e}"
      @logger.error e.backtrace.join("\n")
    ensure
      @logger.info 'closing udp socket'
      udpsock&.close

      @logger.info 'done'
    end
  end
end

Kasa.start
