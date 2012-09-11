#!/usr/bin/env ruby
#
# Sensu Handler: mailer
#
# This handler formats alerts as an email and delays sending until a specified threshold.
#
# Copyright 2012 Lewis Preson
#
# Released under the same terms as Sensu (the MIT license); see LICENSE
# for details.

require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'sensu-handler'
require 'mail'
require 'timeout'
require 'redis'

class DelayedMailer < Sensu::Handler
  def short_name
    @event['client']['name'] + '/' + @event['check']['name']
  end

  def action_to_string
    @event['action'].eql?('resolve') ? "RESOLVED" : "ALERT"
  end

  def handle
    smtp_address = settings['delayed_mailer']['smtp_address'] || 'localhost'
    smtp_port = settings['delayed_mailer']['smtp_port'] || '25'
    smtp_domain = settings['delayed_mailer']['smtp_domain'] || 'localhost.localdomain'

    params = {
        :mail_to => settings['delayed_mailer']['mail_to'],
        :mail_from => settings['delayed_mailer']['mail_from'],
        :smtp_addr => smtp_address,
        :smtp_port => smtp_port,
        :smtp_domain => smtp_domain
    }

    body = "#{@event['check']['output']}"
    subject = "#{action_to_string} - #{short_name}: #{@event['check']['notification']}"

    Mail.defaults do
      delivery_method :smtp, {
          :address => params[:smtp_addr],
          :port => params[:smtp_port],
          :domain => params[:smtp_domain],
          :openssl_verify_mode => 'none'
      }
    end

    if (action_to_string == "ALERT")
      add_key
    end

    if (keys.size >= params[:alerts_in_time_period_before_email] and action_to_string == "ALERT")
      add_negative_email_alert
      puts "emailed"
      send_email
    elsif (action_to_string == "RESOLVED" and negative_email_sent?)
      remove_negative_email_key
      send_email
    end
  end

  def send_email
    begin
      timeout 10 do
        Mail.deliver do
          to params[:mail_to]
          from params[:mail_from]
          subject subject
          body body
        end

        puts 'mail -- sent alert for ' + short_name + ' to ' + params[:mail_to]
      end
    rescue Timeout::Error
      puts 'mail -- timed out while attempting to ' + @event['action'] + ' an incident -- ' + short_name
    end
  end

  def remove_negative_email_key
    begin
      redis = Redis.new(:host => @settings[:redis][:host],
                        :port => @settings[:redis][:port])
      redis.del "dm_#{short_name}-email"
    ensure
      redis.quit
    end
  end

  def add_negative_email_alert
    begin
      redis = Redis.new(:host => @settings[:redis][:host],
                        :port => @settings[:redis][:port])
      redis.keys "dm_#{short_name}-email"
    ensure
      redis.quit
    end
  end

  def keys
    begin
      redis = Redis.new(:host => @settings[:redis][:host],
                        :port => @settings[:redis][:port])
      redis.keys "dm_#{short_name}_*"
    ensure
      redis.quit
    end
  end

  def add_key
    begin
      redis = Redis.new(:host => @settings[:redis][:host],
                        :port => @settings[:redis][:port])

      key= "dm_#{short_name}_#{Time.now.to_i}"
      redis.set key, 1
      redis.expire key, params[:expire]
    ensure
      redis.quit
    end
  end
end

def negative_email_sent?
  begin
    redis = Redis.new(:host => @settings[:redis][:host],
                      :port => @settings[:redis][:port])
    redis.exists "dm_#{short_name}-email"
  ensure
    redis.quit
  end
end
s