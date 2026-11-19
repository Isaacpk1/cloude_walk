require "roda"
require "json"
require "securerandom"
require "waterdrop"
require "helpdesk_contracts"
require_relative "lib/broker/log"
require_relative "lib/broker/signature"
require_relative "lib/broker/dedup"
require_relative "lib/broker/publisher"

module Broker
  TRACEPARENT = /\A00-(?<trace_id>\h{32})-\h{16}-\h{2}\z/

  # Broker de webhooks (ADR-007; 07, seções 3.1 e 6; docs/10, seção 3.2).
  #
  #   POST /webhooks  → 401 assinatura inválida (nada é publicado, nem na DLQ)
  #                   → 422 fora do contrato (vai para a DLQ, sem retentativa)
  #                   → 200 publicado em helpdesk.agent.inbound.v1 (ou repetido)
  #                   → 503 Kafka sem confirmação (a plataforma tenta de novo pelo outbox)
  class App < Roda
    plugin :halt
    plugin :json

    def self.build(producer:, log: Log.new, dedup: Dedup.new, secret: Signature.secret)
      app = Class.new(self)
      app.opts[:broker] = { publisher: Publisher.new(producer:), log:, dedup:, secret: }
      app.freeze.app
    end

    route do |r|
      r.get("up") { { status: "ok" } }

      r.post "webhooks" do
        Webhook.new(r, **opts.fetch(:broker)).call
      end
    end
  end

  # Uma entrega do webhook. Ordem: assinatura sobre o corpo bruto, antes de qualquer parse
  # (RNF-23); depois o contrato (RNF-28); por fim a publicação com confirmação.
  class Webhook
    def initialize(request, publisher:, log:, dedup:, secret:)
      @r = request
      @publisher = publisher
      @log = log
      @dedup = dedup
      @secret = secret
      # Lido como UTF-8 (contêineres rodam com locale C). O HMAC é sobre os mesmos bytes.
      @body = request.body.read.force_encoding(Encoding::UTF_8)
      request.body.rewind
    end

    def call
      authenticate!
      event = validate!
      publish(event)
    rescue Publisher::Unavailable => e
      @log.error("webhook.kafka_unavailable", **trace, status: 503, error: e.message)
      halt(503, { status: "unavailable", error: "Kafka sem confirmação" }, "Retry-After" => "1")
    end

    private

    def authenticate!
      Signature.verify!(@body, @r.env["HTTP_X_HELPDESK_SIGNATURE"], secret: @secret)
    rescue HelpdeskContracts::Signature::Invalid => e
      @log.warn("webhook.unauthorized", **trace, status: 401, reason: e.reason.to_s)
      halt(401, { status: "unauthorized", reason: e.reason.to_s })
    end

    def validate!
      violations = HelpdeskContracts.errors(:agent_inbound, @body).map(&:to_h)
      reject!("contrato", violations) if violations.any?

      event = JSON.parse(@body)
      reject!("event_id_divergente", []) unless event["event_id"] == header_event_id
      reject!("traceparent_invalido", []) unless trace_id_from_header
      event
    end

    def publish(event)
      event_id = event.fetch("event_id")
      claim = @dedup.claim(event_id)
      return repeated(claim, event_id) unless claim == :new

      begin
        report = @publisher.publish(event, body: @body, traceparent: traceparent)
      rescue StandardError
        @dedup.release(event_id)
        raise
      end
      result = { "event_id" => event_id, "topic" => report.topic, "partition" => report.partition, "offset" => report.offset }
      @dedup.confirm(event_id, result)
      @log.info("webhook.published", **trace, status: 200, conversation_id: event["conversation_id"],
                                     brand: event["brand"], **result.transform_keys(&:to_sym))
      { "status" => "published" }.merge(result)
    end

    def repeated(claim, event_id)
      if claim == :in_flight
        @log.info("webhook.in_flight", **trace, status: 503, event_id:)
        halt(503, { status: "in_flight", event_id: }, "Retry-After" => "1")
      end

      @log.info("webhook.duplicate", **trace, status: 200, event_id:)
      { "status" => "duplicate" }.merge(claim)
    end

    def reject!(reason, violations)
      parsed = parse_or_nil
      key = (parsed["conversation_id"] if parsed.is_a?(Hash) && parsed["conversation_id"].is_a?(String)) || header_event_id
      @publisher.dead_letter(body: @body, key:, reason:, violations:, event_id: header_event_id, traceparent:)
      @log.warn("webhook.dead_lettered", **trace, status: 422, reason:, event_id: header_event_id,
                                         violations: violations.map { _1[:pointer] })
      halt(422, { status: "invalid", reason:, violations: })
    end

    def parse_or_nil
      JSON.parse(@body)
    rescue JSON::ParserError
      nil
    end

    def header_event_id = @r.env["HTTP_X_HELPDESK_EVENT_ID"]
    def traceparent = @r.env["HTTP_TRACEPARENT"]
    def trace_id_from_header = TRACEPARENT.match(traceparent.to_s)&.[](:trace_id)
    def trace = { trace_id: trace_id_from_header, event_id: header_event_id }.compact

    def halt(status, body, headers = {})
      @r.halt([ status, { "content-type" => "application/json" }.merge(headers), [ JSON.generate(body) ] ])
    end
  end
end
