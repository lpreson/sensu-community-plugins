#!/usr/bin/env ruby
#
# Sensu Handler: delayed_mailer
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

  @@email_template=
      "<html>
                      <body>
                        <h1>$header</h1>
                        <table>
                            <tr>
                                <td>Time</td>
                                <td>$time</td>
                            </tr>
                            <tr>
                                <td>Occurrences</td>
                                <td>$occurrences</td>
                            </tr>
                            <tr>
                                <td>Flapping</td>
                                <td>$flapping</td>
                            </tr>
                            <tr>
                                <td>Sleep Period</td>
                                <td>$sleep_period</td>
                            </tr>
                        </table>
                      </body>
                    </html>"

  def filter
    #removed filter of repeated, delayed mailer will handle this
    #filter_repeated
    filter_disabled
    filter_silenced
    filter_dependencies
  end

  def short_name
    @event['client']['name'] + '/' + @event['check']['name']
  end

  def action_to_string
    @event['action'].eql?('resolve') ? "RESOLVED" : "ALERT"
  end

  def handle

    subject = "#{action_to_string} - #{short_name}"
    body = build_body

    if action_to_string == "ALERT" and not event_occurred?
      add_key
      send_email(subject, body)
    elsif action_to_string == "RESOLVED" and event_occurred?
      remove_key
      send_email(subject, body)
    end

  end

  def remove_key
    begin
      redis = Redis.new(:host => @settings['redis']['host'],
                        :port => @settings['redis']['port'])
      redis.del key
    ensure
      redis.quit
    end
  end

  def add_key
    begin
      redis = Redis.new(:host => @settings['redis']['host'],
                        :port => @settings['redis']['port'])
      redis.set key, 1
      redis.expire key, @settings['delayed_mailer']['sleep_period']
    ensure
      redis.quit
    end
  end


  def event_occurred?
    begin
      redis = Redis.new(:host => @settings['redis']['host'],
                        :port => @settings['redis']['port'])
      redis.exists key
    ensure
      redis.quit
    end
  end

  def key
    "dm_#{short_name}_occurred"
  end

  def build_body
    body= @@email_template.gsub('$header', @event['check']['output'])
    body= body.gsub('$time', Time.at(@event['check']['issued'].to_i).to_s)
    body= body.gsub('$occurrences', @event['occurrences'].to_s)
    body= body.gsub('$flapping', @event['check']['flapping'].to_s)
    body= body.gsub('$sleep_period', @settings['delayed_mailer']['sleep_period'].to_s)
  end

  def send_email(subject, body)
    begin
      smtp_address = settings['delayed_mailer']['smtp_address'] || 'localhost'
      smtp_port = settings['delayed_mailer']['smtp_port'] || '25'
      smtp_domain = settings['delayed_mailer']['smtp_domain'] || 'localhost.localdomain'
      mail_from= settings['delayed_mailer']['mail_from']

      Mail.defaults do
        delivery_method :smtp, {
            :address => smtp_address,
            :port => smtp_port,
            :domain => smtp_domain,
            :openssl_verify_mode => 'none'
        }
      end

      ARGV.each do |mail_to|
        timeout 10 do
          Mail.deliver do
            to mail_to
            from mail_from
            subject subject
            html_part do
              content_type 'text/html; charset=UTF-8'
              body body
            end
          end
        end

        puts 'mail -- sent alert for ' + short_name + ' to ' + mail_to
      end
    rescue Timeout::Error
      puts 'mail -- timed out while attempting to ' + @event['action'] + ' an incident -- ' + short_name
    end
  end
end