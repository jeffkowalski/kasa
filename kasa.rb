#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'yaml'
require 'rest-client'
require 'json'
require 'tp_link'
require 'influxdb'

LOGFILE = File.join(Dir.home, '.log', 'kasa.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'kasa.yaml')

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

      @logger = Logger.new STDOUT
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'
  class_option :dry_run, type: :boolean, aliases: '-v', desc: "don't log to database"

  desc 'record-status', 'record the current usage data to database'
  def record_status
    setup_logger

    credentials = YAML.load_file CREDENTIALS_PATH
    begin
      sh = TPLink::SmartHome.new('user' => credentials[:user],
                                 'password' => credentials[:password])

      influxdb = options[:dry_run] ? nil : (InfluxDB::Client.new 'kasa')

      sh.devices.each do |device|
        @logger.info device.alias

        sysinfo = sh.send_data(device, 'system' => { 'get_sysinfo' => nil })['responseData']['system']['get_sysinfo']
        timestamp = Time.now.to_i
        @logger.info sysinfo
        data = {
          values: { value: sysinfo['relay_state'] },
          tags: { alias: device.alias },
          timestamp: timestamp
        }
        influxdb.write_point('status', data) unless options[:dry_run]

        next unless sysinfo['feature'].include? 'ENE' # does this device report power?

        power = sh.send_data(device, 'emeter' => { 'get_realtime' => nil })['responseData']['emeter']['get_realtime']['power'].to_f
        timestamp = Time.now.to_i
        @logger.info "power #{power}"
        data = {
          values: { value: power },
          tags: { alias: device.alias },
          timestamp: timestamp
        }
        influxdb.write_point('power', data) unless options[:dry_run]
      end
    rescue TPLink::TPLinkCloudError => e
      @logger.info e
    rescue StandardError => e
      @logger.error e
    end
  end
end

Kasa.start
