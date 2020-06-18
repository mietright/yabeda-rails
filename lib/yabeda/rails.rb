# frozen_string_literal: true

require "yabeda"
require "yabeda/rails/railtie"

module Yabeda
  module Rails
    LONG_RUNNING_REQUEST_BUCKETS = [
      0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, # standard
      30, 60, 120, 300, 600, # Sometimes requests may be really long-running
    ].freeze

    class << self
      def controller_handlers
        @controller_handlers ||= []
      end

      def on_controller_action(&block)
        controller_handlers << block
      end

      def install!
        Yabeda.configure do
          group :rails

          counter   :requests_total, comment: "A counter of the total number of HTTP requests rails processed.",
                                       tags: %i[application environment controller action status format method]

          histogram :request_duration, tags: %i[application environment controller action status format method],
                                       unit: :seconds,
                                       buckets: LONG_RUNNING_REQUEST_BUCKETS,
                                       comment: "A histogram of the response latency."

          histogram :view_runtime, unit: :seconds, buckets: LONG_RUNNING_REQUEST_BUCKETS,
                                   comment: "A histogram of the view rendering time.",
                                   tags: %i[application environment controller action status format method]

          histogram :db_runtime, unit: :seconds, buckets: LONG_RUNNING_REQUEST_BUCKETS,
                                 comment: "A histogram of the activerecord execution time.",
                                 tags: %i[application environment controller action status format method]

          ActiveSupport::Notifications.subscribe "process_action.action_controller" do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            labels = {
              action: event.payload[:params]["action"],
              application: ENV.fetch('APPLICATION_NAME'),
              controller: event.payload[:params]["controller"],
              environment: ENV.fetch('RAILS_ENV', 'development'),
              format: event.payload[:format] || "html",
              method: event.payload[:method].downcase,
              status: event.payload[:status] || "",
            }.compact

            rails_requests_total.increment(labels)
            rails_request_duration.measure(labels, Yabeda::Rails.ms2s(event.duration))
            rails_view_runtime.measure(labels, Yabeda::Rails.ms2s(event.payload[:view_runtime]))
            rails_db_runtime.measure(labels, Yabeda::Rails.ms2s(event.payload[:db_runtime]))

            Yabeda::Rails.controller_handlers.each do |handler|
              handler.call(event, labels)
            end
          end
        end
      end

      def ms2s(ms)
        (ms.to_f / 1000).round(3)
      end
    end
  end
end
