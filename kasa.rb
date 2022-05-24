#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

# see https://github.com/python-kasa/python-kasa
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

class Kasa < RecorderBotBase
  UDP_PORT = 9999
  DISCOVERY_QUERY = { system: { get_sysinfo:  nil },
                      time:   { get_time:     nil },
                      emeter: { get_realtime: nil } }.freeze
  RESPONSE_TIME = 3      # time to collect responses, in seconds
  RESPONSE_LENGTH = 4096 # longest message from device, in bytes

  class_option :experimental, type: :boolean
  no_commands do
    def tcp_command(req, host, port = 9999)
      @logger.debug "requesting from #{host}:#{port}  '#{req}'"
      encrypted_req = TPLinkSmartHomeProtocol.encrypt(req)

      tcpsock = TCPSocket.new(host, port)
      tcpsock.send(encrypted_req, 0)
      tcpsock.flush
      message = tcpsock.read 2048
      puts "message is #{message}"
      tcpsock.close
      response = JSON.parse(TPLinkSmartHomeProtocol.decrypt(message))
      @logger.debug response
      response
    end

    def main
      influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'kasa')

      udpsock = UDPSocket.new
      begin
        udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_BROADCAST, true
        udpsock.setsockopt Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true

        @logger.info "sending broadcast to <broadcast> on port #{UDP_PORT}"
        req = DISCOVERY_QUERY.to_json
        @logger.debug "requesting #{req}"
        encrypted_req = TPLinkSmartHomeProtocol.encrypt(req)
        #@logger.debug encrypted_req
        udpsock.send encrypted_req, 0, '<broadcast>', UDP_PORT

        data = []

        start = Time.now
        while Time.now < (start + RESPONSE_TIME)
          message, info = udpsock.recvfrom_nonblock(RESPONSE_LENGTH, exception: false)
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

            if options[:experimental]
              # tplink_smartplug.py -t 10.0.0.60 -j {\"context\":{\"child_ids\":[\"80062D21C0AEC2B09AA1E67FDDD5C0E11AD78F1800\"]},\"system\":{\"get_sysinfo\":{}},\"emeter\":{\"get_realtime\":{}}}
              # ~/tmp/tplink_smartplug.py -t 192.168.7.242 -j "{\"context\":{\"child_ids\":[\"00\", \"01\"]},\"system\":{\"get_sysinfo\":null},\"emeter\":{\"get_realtime\":null}}"
              child_ids = device['system']['get_sysinfo']['children'].collect { |child| child['id'].to_s }
              query = { context: { child_ids: child_ids } }.merge DISCOVERY_QUERY
              query = DISCOVERY_QUERY
              tcp_command query.to_json, '192.168.7.242'
              exit
            end
          else
            name = device['system']['get_sysinfo']['alias']
            state = device['system']['get_sysinfo']['relay_state']
            @logger.info "device '#{name}' state = #{state}"

            data.push({ series:    'status',
                        values:    { value: state },
                        tags:      { alias: name },
                        timestamp: timestamp })

            unless !device['emeter'].key?('get_realtime') || device['emeter']['get_realtime']['err_code'] != 0
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
      ensure
        @logger.info 'closing udp socket'
        udpsock&.close
      end
    end
  end
end

Kasa.start
