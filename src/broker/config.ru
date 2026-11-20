require_relative "app"
require_relative "config/waterdrop"

producer = Broker::Kafka.producer
at_exit { producer.close }

run Broker::App.build(producer:)
