SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: audit_events_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_events_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'auditoria é imutável (RN-54): registre um novo evento';
END;
$$;


--
-- Name: dead_letters_retention(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dead_letters_retention() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.created_at > (now() AT TIME ZONE 'UTC') - interval '7 days' THEN
    RAISE EXCEPTION 'dead_letters: retenção mínima de 7 dias (RN-48), registro %', OLD.id;
  END IF;
  RETURN OLD;
END $$;


--
-- Name: handoff_summaries_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handoff_summaries_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'handoff_summaries é só inserção (RN-39, RN-54): o primeiro resumo do handoff vale';
END;
$$;


--
-- Name: eval_runs_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.eval_runs_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'eval_runs é só de inserção';
END $$;


--
-- Name: queue_versions_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_versions_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'versão de fila é imutável (RN-20): crie uma versão nova';
END;
$$;


--
-- Name: routing_rulesets_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.routing_rulesets_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'routing_rulesets é só inserção (RN-20): publique uma versão nova';
END;
$$;


--
-- Name: routing_rulesets_queues_of_brand(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.routing_rulesets_queues_of_brand() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  bad text;
BEGIN
  SELECT rule ->> 'queue_id' INTO bad
    FROM jsonb_array_elements(NEW.rules -> 'rules') AS rule
   WHERE NOT EXISTS (
           SELECT 1 FROM queues q
            WHERE q.id::text = rule ->> 'queue_id' AND q.brand_id = NEW.brand_id AND q.active)
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'regra aponta para fila % que não é ativa da marca % (RN-15)', bad, NEW.brand_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM queues q WHERE q.id = NEW.default_queue_id AND q.active) THEN
    RAISE EXCEPTION 'fila padrão % inativa (RF-17)', NEW.default_queue_id;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: tickets_evaluation_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tickets_evaluation_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'tickets.evaluation não muda depois da criação';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ai_turns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_turns (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    ticket_id bigint NOT NULL,
    turn integer NOT NULL,
    context_until_seq integer NOT NULL,
    assignment_version integer NOT NULL,
    context jsonb NOT NULL,
    event_id uuid NOT NULL,
    status character varying DEFAULT 'eligible'::character varying NOT NULL,
    deadline_at timestamp(6) without time zone NOT NULL,
    applied_event_id uuid,
    response jsonb,
    response_received_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    context_version integer,
    context_digest character varying,
    CONSTRAINT ai_turns_applied_event_check CHECK ((((status)::text = 'applied'::text) = (applied_event_id IS NOT NULL))),
    CONSTRAINT ai_turns_context_digest_check CHECK (((context_digest IS NULL) OR ((context_digest)::text ~ '^sha256:[0-9a-f]{64}$'::text))),
    CONSTRAINT ai_turns_context_until_seq_check CHECK ((context_until_seq >= 1)),
    CONSTRAINT ai_turns_context_version_check CHECK (((context_version IS NULL) OR (context_version >= 0))),
    CONSTRAINT ai_turns_context_version_digest_check CHECK (((context_version IS NULL) = (context_digest IS NULL))),
    CONSTRAINT ai_turns_status_check CHECK (((status)::text = ANY (ARRAY[('eligible'::character varying)::text, ('applied'::character varying)::text, ('superseded'::character varying)::text, ('expired'::character varying)::text]))),
    CONSTRAINT ai_turns_turn_check CHECK ((turn >= 1))
);


--
-- Name: ai_turns_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_turns_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_turns_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_turns_id_seq OWNED BY public.ai_turns.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id bigint NOT NULL,
    occurred_at timestamp(6) without time zone DEFAULT clock_timestamp() NOT NULL,
    brand_id bigint NOT NULL,
    ticket_id bigint,
    actor_type character varying NOT NULL,
    actor_id bigint,
    event_type character varying NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    trace_id character varying NOT NULL,
    ruleset_version integer,
    agent_model character varying,
    agent_version character varying
);


--
-- Name: audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_events_id_seq OWNED BY public.audit_events.id;


--
-- Name: brands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brands (
    id bigint NOT NULL,
    slug character varying NOT NULL,
    name character varying NOT NULL,
    locale character varying DEFAULT 'pt-BR'::character varying NOT NULL,
    timezone character varying DEFAULT 'America/Sao_Paulo'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: brands_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.brands_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: brands_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.brands_id_seq OWNED BY public.brands.id;


--
-- Name: customer_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_identities (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    channel character varying NOT NULL,
    external_id character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT customer_identities_channel_check CHECK (((channel)::text = ANY (ARRAY[('chat'::character varying)::text, ('whatsapp'::character varying)::text, ('email'::character varying)::text])))
);


--
-- Name: customer_identities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.customer_identities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: customer_identities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.customer_identities_id_seq OWNED BY public.customer_identities.id;


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    display_name character varying NOT NULL,
    verified boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: customers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.customers_id_seq OWNED BY public.customers.id;


--
-- Name: dead_letters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dead_letters (
    id bigint NOT NULL,
    brand_id bigint,
    ticket_id bigint,
    topic character varying NOT NULL,
    partition integer NOT NULL,
    "offset" bigint NOT NULL,
    source character varying NOT NULL,
    reason character varying NOT NULL,
    event_id character varying,
    trace_id character varying,
    turn integer,
    violations jsonb DEFAULT '[]'::jsonb NOT NULL,
    headers jsonb DEFAULT '{}'::jsonb NOT NULL,
    payload text NOT NULL,
    error text,
    attempts integer DEFAULT 0 NOT NULL,
    outcome character varying,
    reprocessed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT dead_letters_outcome_check CHECK (((outcome IS NULL) OR ((outcome)::text = ANY ((ARRAY['escalated'::character varying, 'audited'::character varying, 'uncorrelated'::character varying])::text[])))),
    CONSTRAINT dead_letters_source_check CHECK (((source)::text = ANY ((ARRAY['broker'::character varying, 'agent-mock'::character varying, 'platform'::character varying, 'unknown'::character varying])::text[]))),
    CONSTRAINT dead_letters_ticket_brand_check CHECK (((ticket_id IS NULL) OR (brand_id IS NOT NULL)))
);


--
-- Name: dead_letters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dead_letters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dead_letters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dead_letters_id_seq OWNED BY public.dead_letters.id;


--
-- Name: deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deliveries (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    ticket_id bigint NOT NULL,
    message_id bigint NOT NULL,
    delivery_id uuid DEFAULT gen_random_uuid() NOT NULL,
    seq integer NOT NULL,
    channel character varying NOT NULL,
    provider_account character varying NOT NULL,
    kind character varying NOT NULL,
    ai_assignment_version integer,
    ai_first_pending_seq integer,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    lease_until timestamp(6) without time zone,
    provider_message_id character varying,
    last_error text,
    trace_id character varying NOT NULL,
    delivered_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT deliveries_attempts_check CHECK ((attempts >= 0)),
    CONSTRAINT deliveries_channel_check CHECK (((channel)::text = ANY (ARRAY[('chat'::character varying)::text, ('whatsapp'::character varying)::text, ('email'::character varying)::text]))),
    CONSTRAINT deliveries_delivered_at_check CHECK ((((status)::text = 'delivered'::text) = (delivered_at IS NOT NULL))),
    CONSTRAINT deliveries_delivered_confirmation_check CHECK ((((status)::text <> 'delivered'::text) OR (provider_message_id IS NOT NULL))),
    CONSTRAINT deliveries_kind_check CHECK (((kind)::text = ANY (ARRAY[('reply'::character varying)::text, ('resolution'::character varying)::text, ('progress'::character varying)::text, ('handoff_notice'::character varying)::text, ('analyst'::character varying)::text]))),
    CONSTRAINT deliveries_seq_check CHECK ((seq >= 1)),
    CONSTRAINT deliveries_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('sending'::character varying)::text, ('delivered'::character varying)::text, ('cancelled'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.deliveries_id_seq OWNED BY public.deliveries.id;


--
-- Name: eval_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.eval_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    scenario character varying NOT NULL,
    status character varying NOT NULL,
    agent_model character varying NOT NULL,
    agent_version character varying NOT NULL,
    config_hash character varying,
    expected jsonb DEFAULT '{}'::jsonb NOT NULL,
    observed jsonb DEFAULT '{}'::jsonb NOT NULL,
    checks jsonb DEFAULT '[]'::jsonb NOT NULL,
    brand_id bigint NOT NULL,
    ticket_id bigint,
    trace_id character varying,
    error text,
    started_at timestamp(6) without time zone NOT NULL,
    finished_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT eval_runs_checks_check CHECK ((jsonb_typeof(checks) = 'array'::text)),
    CONSTRAINT eval_runs_status_check CHECK (((status)::text = ANY (ARRAY[('passed'::character varying)::text, ('failed'::character varying)::text, ('error'::character varying)::text])))
);


--
-- Name: handoff_summaries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.handoff_summaries (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    ticket_id bigint NOT NULL,
    from_assignment_version integer NOT NULL,
    source character varying NOT NULL,
    status character varying NOT NULL,
    fields jsonb,
    missing_reason character varying,
    trace_id character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT handoff_summaries_source_check CHECK (((source)::text = ANY ((ARRAY['agent'::character varying, 'platform'::character varying])::text[]))),
    CONSTRAINT handoff_summaries_status_check CHECK (((status)::text = ANY ((ARRAY['available'::character varying, 'missing'::character varying])::text[]))),
    CONSTRAINT handoff_summaries_status_fields_check CHECK (((((status)::text = 'available'::text) AND (fields IS NOT NULL)) OR (((status)::text = 'missing'::text) AND (missing_reason IS NOT NULL))))
);


--
-- Name: handoff_summaries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.handoff_summaries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: handoff_summaries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.handoff_summaries_id_seq OWNED BY public.handoff_summaries.id;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    ticket_id bigint NOT NULL,
    provider_account character varying NOT NULL,
    channel character varying NOT NULL,
    direction character varying NOT NULL,
    author_type character varying NOT NULL,
    author_id bigint,
    body text NOT NULL,
    internal boolean DEFAULT false NOT NULL,
    external_id character varying,
    seq integer NOT NULL,
    trace_id character varying NOT NULL,
    subject character varying,
    attachments jsonb DEFAULT '[]'::jsonb NOT NULL,
    provider_payload jsonb,
    received_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT messages_author_type_check CHECK (((author_type)::text = ANY (ARRAY[('customer'::character varying)::text, ('bot'::character varying)::text, ('analyst'::character varying)::text, ('system'::character varying)::text]))),
    CONSTRAINT messages_direction_check CHECK (((direction)::text = ANY (ARRAY[('inbound'::character varying)::text, ('outbound'::character varying)::text])))
);


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messages_id_seq OWNED BY public.messages.id;


--
-- Name: outbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbox_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brand_id bigint NOT NULL,
    ticket_id bigint,
    event_type character varying NOT NULL,
    dedup_key character varying,
    payload jsonb NOT NULL,
    trace_id character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    next_attempt_at timestamp(6) without time zone NOT NULL,
    lease_until timestamp(6) without time zone,
    published_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text,
    CONSTRAINT outbox_events_attempts_check CHECK ((attempts >= 0))
);


--
-- Name: processed_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.processed_events (
    consumer character varying NOT NULL,
    event_id uuid NOT NULL,
    processed_at timestamp(6) without time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: provider_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_accounts (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    channel character varying NOT NULL,
    slug character varying NOT NULL,
    phone_number_id character varying,
    secret text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    evaluation boolean DEFAULT false NOT NULL,
    CONSTRAINT provider_accounts_channel_check CHECK (((channel)::text = ANY (ARRAY[('chat'::character varying)::text, ('whatsapp'::character varying)::text, ('email'::character varying)::text]))),
    CONSTRAINT provider_accounts_whatsapp_phone_check CHECK ((((channel)::text <> 'whatsapp'::text) OR (phone_number_id IS NOT NULL)))
);


--
-- Name: provider_accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provider_accounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_accounts_id_seq OWNED BY public.provider_accounts.id;


--
-- Name: queue_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.queue_versions (
    id bigint NOT NULL,
    queue_id bigint NOT NULL,
    version integer NOT NULL,
    name character varying NOT NULL,
    ai_first boolean DEFAULT true NOT NULL,
    sla_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    business_hours jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by_id bigint,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: queue_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.queue_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: queue_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.queue_versions_id_seq OWNED BY public.queue_versions.id;


--
-- Name: queues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.queues (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    team_id bigint NOT NULL,
    current_version_id bigint,
    is_default boolean DEFAULT false NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    escalation boolean DEFAULT false NOT NULL
);


--
-- Name: queues_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.queues_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: queues_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.queues_id_seq OWNED BY public.queues.id;


--
-- Name: routing_rulesets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.routing_rulesets (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    version integer NOT NULL,
    rules jsonb NOT NULL,
    default_queue_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT routing_rulesets_rules_check CHECK ((jsonb_typeof((rules -> 'rules'::text)) = 'array'::text)),
    CONSTRAINT routing_rulesets_version_check CHECK ((version >= 1))
);


--
-- Name: routing_rulesets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.routing_rulesets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: routing_rulesets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.routing_rulesets_id_seq OWNED BY public.routing_rulesets.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: team_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_memberships (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    team_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: team_memberships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.team_memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: team_memberships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.team_memberships_id_seq OWNED BY public.team_memberships.id;


--
-- Name: teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teams (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: teams_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.teams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: teams_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.teams_id_seq OWNED BY public.teams.id;


--
-- Name: tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tickets (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    channel character varying NOT NULL,
    state character varying DEFAULT 'novo'::character varying NOT NULL,
    category character varying,
    priority character varying,
    queue_id bigint,
    queue_version integer,
    ruleset_version integer,
    assignee_id bigint,
    tags character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    linked_ticket_id bigint,
    latest_customer_seq integer DEFAULT 0 NOT NULL,
    assignment_version integer DEFAULT 0 NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    first_pending_seq integer,
    first_pending_at timestamp(6) without time zone,
    dispatch_due_at timestamp(6) without time zone,
    ai_deadline_at timestamp(6) without time zone,
    context_version integer DEFAULT 0 NOT NULL,
    evaluation boolean DEFAULT false NOT NULL,
    progress_due_at timestamp(6) without time zone,
    ai_turns_count integer DEFAULT 0 NOT NULL,
    CONSTRAINT tickets_ai_turns_count_check CHECK ((ai_turns_count >= 0)),
    CONSTRAINT tickets_channel_check CHECK (((channel)::text = ANY (ARRAY[('chat'::character varying)::text, ('whatsapp'::character varying)::text, ('email'::character varying)::text]))),
    CONSTRAINT tickets_context_version_check CHECK ((context_version >= 0)),
    CONSTRAINT tickets_dispatch_requires_cycle_check CHECK (((dispatch_due_at IS NULL) OR (first_pending_at IS NOT NULL))),
    CONSTRAINT tickets_first_pending_pair_check CHECK (((first_pending_seq IS NULL) = (first_pending_at IS NULL))),
    CONSTRAINT tickets_first_pending_seq_check CHECK (((first_pending_seq IS NULL) OR (first_pending_seq >= 1))),
    CONSTRAINT tickets_progress_requires_cycle_check CHECK (((progress_due_at IS NULL) OR (first_pending_at IS NOT NULL))),
    CONSTRAINT tickets_state_check CHECK (((state)::text = ANY (ARRAY[('novo'::character varying)::text, ('em_triagem'::character varying)::text, ('com_ia'::character varying)::text, ('aguardando_humano'::character varying)::text, ('com_analista'::character varying)::text, ('aguardando_cliente'::character varying)::text, ('resolvido'::character varying)::text, ('fechado'::character varying)::text])))
);


--
-- Name: tickets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tickets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tickets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tickets_id_seq OWNED BY public.tickets.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    name character varying NOT NULL,
    email character varying NOT NULL,
    kind character varying DEFAULT 'human'::character varying NOT NULL,
    role character varying DEFAULT 'analyst'::character varying NOT NULL,
    status character varying DEFAULT 'offline'::character varying NOT NULL,
    capacity integer DEFAULT 5 NOT NULL,
    active_count integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT users_capacity_check CHECK (((active_count >= 0) AND (active_count <= capacity))),
    CONSTRAINT users_kind_check CHECK (((kind)::text = ANY (ARRAY[('human'::character varying)::text, ('bot'::character varying)::text]))),
    CONSTRAINT users_role_check CHECK (((role)::text = ANY (ARRAY[('supervisor'::character varying)::text, ('analyst'::character varying)::text, ('agent'::character varying)::text]))),
    CONSTRAINT users_status_check CHECK (((status)::text = ANY (ARRAY[('online'::character varying)::text, ('pausa'::character varying)::text, ('offline'::character varying)::text])))
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: ai_turns id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_turns ALTER COLUMN id SET DEFAULT nextval('public.ai_turns_id_seq'::regclass);


--
-- Name: audit_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ALTER COLUMN id SET DEFAULT nextval('public.audit_events_id_seq'::regclass);


--
-- Name: brands id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brands ALTER COLUMN id SET DEFAULT nextval('public.brands_id_seq'::regclass);


--
-- Name: customer_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_identities ALTER COLUMN id SET DEFAULT nextval('public.customer_identities_id_seq'::regclass);


--
-- Name: customers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers ALTER COLUMN id SET DEFAULT nextval('public.customers_id_seq'::regclass);


--
-- Name: dead_letters id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dead_letters ALTER COLUMN id SET DEFAULT nextval('public.dead_letters_id_seq'::regclass);


--
-- Name: deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries ALTER COLUMN id SET DEFAULT nextval('public.deliveries_id_seq'::regclass);


--
-- Name: handoff_summaries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handoff_summaries ALTER COLUMN id SET DEFAULT nextval('public.handoff_summaries_id_seq'::regclass);


--
-- Name: messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages ALTER COLUMN id SET DEFAULT nextval('public.messages_id_seq'::regclass);


--
-- Name: provider_accounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_accounts ALTER COLUMN id SET DEFAULT nextval('public.provider_accounts_id_seq'::regclass);


--
-- Name: queue_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queue_versions ALTER COLUMN id SET DEFAULT nextval('public.queue_versions_id_seq'::regclass);


--
-- Name: queues id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues ALTER COLUMN id SET DEFAULT nextval('public.queues_id_seq'::regclass);


--
-- Name: routing_rulesets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routing_rulesets ALTER COLUMN id SET DEFAULT nextval('public.routing_rulesets_id_seq'::regclass);


--
-- Name: team_memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships ALTER COLUMN id SET DEFAULT nextval('public.team_memberships_id_seq'::regclass);


--
-- Name: teams id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams ALTER COLUMN id SET DEFAULT nextval('public.teams_id_seq'::regclass);


--
-- Name: tickets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tickets ALTER COLUMN id SET DEFAULT nextval('public.tickets_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: ai_turns ai_turns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_turns
    ADD CONSTRAINT ai_turns_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: brands brands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_pkey PRIMARY KEY (id);


--
-- Name: customer_identities customer_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_identities
    ADD CONSTRAINT customer_identities_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: dead_letters dead_letters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dead_letters
    ADD CONSTRAINT dead_letters_pkey PRIMARY KEY (id);


--
-- Name: deliveries deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_pkey PRIMARY KEY (id);


--
-- Name: eval_runs eval_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_runs
    ADD CONSTRAINT eval_runs_pkey PRIMARY KEY (id);


--
-- Name: handoff_summaries handoff_summaries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handoff_summaries
    ADD CONSTRAINT handoff_summaries_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: outbox_events outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT outbox_events_pkey PRIMARY KEY (id);


--
-- Name: processed_events processed_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_events
    ADD CONSTRAINT processed_events_pkey PRIMARY KEY (consumer, event_id);


--
-- Name: provider_accounts provider_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_accounts
    ADD CONSTRAINT provider_accounts_pkey PRIMARY KEY (id);


--
-- Name: queue_versions queue_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queue_versions
    ADD CONSTRAINT queue_versions_pkey PRIMARY KEY (id);


--
-- Name: queues queues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues
    ADD CONSTRAINT queues_pkey PRIMARY KEY (id);


--
-- Name: routing_rulesets routing_rulesets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routing_rulesets
    ADD CONSTRAINT routing_rulesets_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: team_memberships team_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT team_memberships_pkey PRIMARY KEY (id);


--
-- Name: teams teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_pkey PRIMARY KEY (id);


--
-- Name: tickets tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tickets
    ADD CONSTRAINT tickets_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_on_ticket_id_from_assignment_version_5e5bf8094e; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_ticket_id_from_assignment_version_5e5bf8094e ON public.handoff_summaries USING btree (ticket_id, from_assignment_version);


--
-- Name: index_ai_turns_eligible_deadline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_turns_eligible_deadline ON public.ai_turns USING btree (deadline_at) WHERE ((status)::text = 'eligible'::text);


--
-- Name: index_ai_turns_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_turns_on_brand_id ON public.ai_turns USING btree (brand_id);


--
-- Name: index_ai_turns_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_turns_on_event_id ON public.ai_turns USING btree (event_id);


--
-- Name: index_ai_turns_on_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_turns_on_ticket_id ON public.ai_turns USING btree (ticket_id);


--
-- Name: index_ai_turns_on_ticket_id_and_turn; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_turns_on_ticket_id_and_turn ON public.ai_turns USING btree (ticket_id, turn);


--
-- Name: index_audit_events_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_brand_id ON public.audit_events USING btree (brand_id);


--
-- Name: index_audit_events_on_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_ticket_id ON public.audit_events USING btree (ticket_id);


--
-- Name: index_audit_events_on_ticket_id_and_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_ticket_id_and_occurred_at ON public.audit_events USING btree (ticket_id, occurred_at);


--
-- Name: index_brands_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_brands_on_slug ON public.brands USING btree (slug);


--
-- Name: index_customer_identities_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_customer_identities_on_brand_id ON public.customer_identities USING btree (brand_id);


--
-- Name: index_customer_identities_on_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_customer_identities_on_customer_id ON public.customer_identities USING btree (customer_id);


--
-- Name: index_customer_identities_unique_per_brand; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_customer_identities_unique_per_brand ON public.customer_identities USING btree (brand_id, channel, external_id);


--
-- Name: index_customers_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_customers_on_brand_id ON public.customers USING btree (brand_id);


--
-- Name: index_customers_on_id_and_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_customers_on_id_and_brand_id ON public.customers USING btree (id, brand_id);


--
-- Name: index_dead_letters_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dead_letters_on_brand_id ON public.dead_letters USING btree (brand_id);


--
-- Name: index_dead_letters_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dead_letters_on_created_at ON public.dead_letters USING btree (created_at);


--
-- Name: index_dead_letters_on_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dead_letters_on_event_id ON public.dead_letters USING btree (event_id);


--
-- Name: index_dead_letters_on_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dead_letters_on_ticket_id ON public.dead_letters USING btree (ticket_id);


--
-- Name: index_dead_letters_on_topic_and_partition_and_offset; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_dead_letters_on_topic_and_partition_and_offset ON public.dead_letters USING btree (topic, partition, "offset");


--
-- Name: index_deliveries_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_deliveries_on_brand_id ON public.deliveries USING btree (brand_id);


--
-- Name: index_deliveries_on_delivery_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_deliveries_on_delivery_id ON public.deliveries USING btree (delivery_id);


--
-- Name: index_deliveries_on_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_deliveries_on_message_id ON public.deliveries USING btree (message_id);


--
-- Name: index_deliveries_on_provider_message; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_deliveries_on_provider_message ON public.deliveries USING btree (brand_id, channel, provider_account, provider_message_id) WHERE (provider_message_id IS NOT NULL);


--
-- Name: index_deliveries_on_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_deliveries_on_ticket_id ON public.deliveries USING btree (ticket_id);


--
-- Name: index_deliveries_on_ticket_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_deliveries_on_ticket_id_and_seq ON public.deliveries USING btree (ticket_id, seq);


--
-- Name: index_deliveries_one_progress_per_cycle; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_deliveries_one_progress_per_cycle ON public.deliveries USING btree (ticket_id, ai_first_pending_seq) WHERE ((kind)::text = 'progress'::text);


--
-- Name: index_deliveries_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_deliveries_open ON public.deliveries USING btree (ticket_id, seq) WHERE ((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('sending'::character varying)::text]));


--
-- Name: index_eval_runs_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_eval_runs_on_brand_id ON public.eval_runs USING btree (brand_id);


--
-- Name: index_eval_runs_on_scenario_and_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_eval_runs_on_scenario_and_started_at ON public.eval_runs USING btree (scenario, started_at);


--
-- Name: index_eval_runs_on_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_eval_runs_on_ticket_id ON public.eval_runs USING btree (ticket_id);


--
-- Name: index_handoff_summaries_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_handoff_summaries_on_brand_id ON public.handoff_summaries USING btree (brand_id);


--
-- Name: index_messages_dedup_per_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_messages_dedup_per_provider ON public.messages USING btree (brand_id, provider_account, channel, external_id) WHERE (external_id IS NOT NULL);


--
-- Name: index_messages_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_brand_id ON public.messages USING btree (brand_id);


--
-- Name: index_messages_on_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_ticket_id ON public.messages USING btree (ticket_id);


--
-- Name: index_messages_on_ticket_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_messages_on_ticket_id_and_seq ON public.messages USING btree (ticket_id, seq);


--
-- Name: index_outbox_events_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_events_on_brand_id ON public.outbox_events USING btree (brand_id);


--
-- Name: index_outbox_events_on_dedup_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbox_events_on_dedup_key ON public.outbox_events USING btree (dedup_key) WHERE (dedup_key IS NOT NULL);


--
-- Name: index_outbox_events_on_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_events_on_ticket_id ON public.outbox_events USING btree (ticket_id);


--
-- Name: index_outbox_events_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_events_open ON public.outbox_events USING btree (next_attempt_at) WHERE (completed_at IS NULL);


--
-- Name: index_provider_accounts_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_provider_accounts_on_brand_id ON public.provider_accounts USING btree (brand_id);


--
-- Name: index_provider_accounts_on_phone_number_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_provider_accounts_on_phone_number_id ON public.provider_accounts USING btree (phone_number_id) WHERE (phone_number_id IS NOT NULL);


--
-- Name: index_provider_accounts_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_provider_accounts_on_slug ON public.provider_accounts USING btree (slug);


--
-- Name: index_queue_versions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_queue_versions_on_created_by_id ON public.queue_versions USING btree (created_by_id);


--
-- Name: index_queue_versions_on_id_and_queue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_queue_versions_on_id_and_queue_id ON public.queue_versions USING btree (id, queue_id);


--
-- Name: index_queue_versions_on_queue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_queue_versions_on_queue_id ON public.queue_versions USING btree (queue_id);


--
-- Name: index_queue_versions_on_queue_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_queue_versions_on_queue_id_and_version ON public.queue_versions USING btree (queue_id, version);


--
-- Name: index_queues_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_queues_on_brand_id ON public.queues USING btree (brand_id);


--
-- Name: index_queues_on_id_and_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_queues_on_id_and_brand_id ON public.queues USING btree (id, brand_id);


--
-- Name: index_queues_on_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_queues_on_team_id ON public.queues USING btree (team_id);


--
-- Name: index_queues_one_default_per_brand; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_queues_one_default_per_brand ON public.queues USING btree (brand_id) WHERE is_default;


--
-- Name: index_queues_one_escalation_per_brand; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_queues_one_escalation_per_brand ON public.queues USING btree (brand_id) WHERE (escalation AND active);


--
-- Name: index_routing_rulesets_on_brand_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_routing_rulesets_on_brand_id_and_version ON public.routing_rulesets USING btree (brand_id, version);


--
-- Name: index_routing_rulesets_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_routing_rulesets_on_created_by_id ON public.routing_rulesets USING btree (created_by_id);


--
-- Name: index_team_memberships_on_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_team_memberships_on_team_id ON public.team_memberships USING btree (team_id);


--
-- Name: index_team_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_team_memberships_on_user_id ON public.team_memberships USING btree (user_id);


--
-- Name: index_team_memberships_on_user_id_and_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_team_memberships_on_user_id_and_team_id ON public.team_memberships USING btree (user_id, team_id);


--
-- Name: index_teams_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_teams_on_brand_id ON public.teams USING btree (brand_id);


--
-- Name: index_teams_on_brand_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_teams_on_brand_id_and_name ON public.teams USING btree (brand_id, name);


--
-- Name: index_teams_on_id_and_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_teams_on_id_and_brand_id ON public.teams USING btree (id, brand_id);


--
-- Name: index_tickets_dispatch_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tickets_dispatch_due ON public.tickets USING btree (dispatch_due_at) WHERE (dispatch_due_at IS NOT NULL);


--
-- Name: index_tickets_on_ai_deadline_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tickets_on_ai_deadline_at ON public.tickets USING btree (ai_deadline_at) WHERE (ai_deadline_at IS NOT NULL);


--
-- Name: index_tickets_on_assignee_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tickets_on_assignee_id ON public.tickets USING btree (assignee_id);


--
-- Name: index_tickets_on_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tickets_on_brand_id ON public.tickets USING btree (brand_id);


--
-- Name: index_tickets_on_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tickets_on_customer_id ON public.tickets USING btree (customer_id);


--
-- Name: index_tickets_on_id_and_brand_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tickets_on_id_and_brand_id ON public.tickets USING btree (id, brand_id);


--
-- Name: index_tickets_on_linked_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tickets_on_linked_ticket_id ON public.tickets USING btree (linked_ticket_id);


--
-- Name: index_tickets_on_progress_due_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tickets_on_progress_due_at ON public.tickets USING btree (progress_due_at) WHERE (progress_due_at IS NOT NULL);


--
-- Name: index_tickets_on_queue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tickets_on_queue_id ON public.tickets USING btree (queue_id);


--
-- Name: index_tickets_one_open_per_customer_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tickets_one_open_per_customer_channel ON public.tickets USING btree (customer_id, channel) WHERE ((state)::text <> 'fechado'::text);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: audit_events audit_events_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_immutable BEFORE DELETE OR UPDATE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.audit_events_immutable();


--
-- Name: dead_letters dead_letters_retention; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER dead_letters_retention BEFORE DELETE ON public.dead_letters FOR EACH ROW EXECUTE FUNCTION public.dead_letters_retention();


--
-- Name: handoff_summaries handoff_summaries_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER handoff_summaries_immutable BEFORE DELETE OR UPDATE ON public.handoff_summaries FOR EACH ROW EXECUTE FUNCTION public.handoff_summaries_immutable();


--
-- Name: eval_runs eval_runs_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER eval_runs_no_update BEFORE DELETE OR UPDATE ON public.eval_runs FOR EACH ROW EXECUTE FUNCTION public.eval_runs_immutable();


--
-- Name: queue_versions queue_versions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER queue_versions_immutable BEFORE DELETE OR UPDATE ON public.queue_versions FOR EACH ROW EXECUTE FUNCTION public.queue_versions_immutable();


--
-- Name: routing_rulesets routing_rulesets_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER routing_rulesets_immutable BEFORE DELETE OR UPDATE ON public.routing_rulesets FOR EACH ROW EXECUTE FUNCTION public.routing_rulesets_immutable();


--
-- Name: routing_rulesets routing_rulesets_queues_of_brand; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER routing_rulesets_queues_of_brand BEFORE INSERT ON public.routing_rulesets FOR EACH ROW EXECUTE FUNCTION public.routing_rulesets_queues_of_brand();


--
-- Name: tickets tickets_evaluation_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tickets_evaluation_immutable BEFORE UPDATE OF evaluation ON public.tickets FOR EACH ROW WHEN ((new.evaluation IS DISTINCT FROM old.evaluation)) EXECUTE FUNCTION public.tickets_evaluation_immutable();


--
-- Name: ai_turns fk_ai_turns_ticket_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_turns
    ADD CONSTRAINT fk_ai_turns_ticket_same_brand FOREIGN KEY (ticket_id, brand_id) REFERENCES public.tickets(id, brand_id);


--
-- Name: audit_events fk_audit_events_ticket_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_audit_events_ticket_same_brand FOREIGN KEY (ticket_id, brand_id) REFERENCES public.tickets(id, brand_id);


--
-- Name: customer_identities fk_customer_identities_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_identities
    ADD CONSTRAINT fk_customer_identities_same_brand FOREIGN KEY (customer_id, brand_id) REFERENCES public.customers(id, brand_id);


--
-- Name: dead_letters fk_dead_letters_ticket_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dead_letters
    ADD CONSTRAINT fk_dead_letters_ticket_same_brand FOREIGN KEY (ticket_id, brand_id) REFERENCES public.tickets(id, brand_id);


--
-- Name: deliveries fk_deliveries_ticket_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT fk_deliveries_ticket_same_brand FOREIGN KEY (ticket_id, brand_id) REFERENCES public.tickets(id, brand_id);


--
-- Name: eval_runs fk_eval_runs_ticket_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_runs
    ADD CONSTRAINT fk_eval_runs_ticket_same_brand FOREIGN KEY (ticket_id, brand_id) REFERENCES public.tickets(id, brand_id);


--
-- Name: handoff_summaries fk_handoff_summaries_ticket_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handoff_summaries
    ADD CONSTRAINT fk_handoff_summaries_ticket_same_brand FOREIGN KEY (ticket_id, brand_id) REFERENCES public.tickets(id, brand_id);


--
-- Name: messages fk_messages_ticket_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_messages_ticket_same_brand FOREIGN KEY (ticket_id, brand_id) REFERENCES public.tickets(id, brand_id);


--
-- Name: outbox_events fk_outbox_events_ticket_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT fk_outbox_events_ticket_same_brand FOREIGN KEY (ticket_id, brand_id) REFERENCES public.tickets(id, brand_id);


--
-- Name: queues fk_queues_current_version_of_queue; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues
    ADD CONSTRAINT fk_queues_current_version_of_queue FOREIGN KEY (current_version_id, id) REFERENCES public.queue_versions(id, queue_id);


--
-- Name: queues fk_queues_team_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues
    ADD CONSTRAINT fk_queues_team_same_brand FOREIGN KEY (team_id, brand_id) REFERENCES public.teams(id, brand_id);


--
-- Name: messages fk_rails_19770f78ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_19770f78ed FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: messages fk_rails_1a0b99fe7e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_1a0b99fe7e FOREIGN KEY (ticket_id) REFERENCES public.tickets(id);


--
-- Name: dead_letters fk_rails_1a56f359d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dead_letters
    ADD CONSTRAINT fk_rails_1a56f359d6 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: tickets fk_rails_1dfd143528; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tickets
    ADD CONSTRAINT fk_rails_1dfd143528 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: queues fk_rails_2167254322; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues
    ADD CONSTRAINT fk_rails_2167254322 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: customer_identities fk_rails_22532c432d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_identities
    ADD CONSTRAINT fk_rails_22532c432d FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: eval_runs fk_rails_358a9c83c1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_runs
    ADD CONSTRAINT fk_rails_358a9c83c1 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: eval_runs fk_rails_3d8538fc74; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eval_runs
    ADD CONSTRAINT fk_rails_3d8538fc74 FOREIGN KEY (ticket_id) REFERENCES public.tickets(id);


--
-- Name: deliveries fk_rails_4feecaaa86; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT fk_rails_4feecaaa86 FOREIGN KEY (message_id) REFERENCES public.messages(id);


--
-- Name: teams fk_rails_5545c98c48; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT fk_rails_5545c98c48 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: tickets fk_rails_5685ed71b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tickets
    ADD CONSTRAINT fk_rails_5685ed71b0 FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: team_memberships fk_rails_5aba9331a7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT fk_rails_5aba9331a7 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: tickets fk_rails_5ce8e37f94; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tickets
    ADD CONSTRAINT fk_rails_5ce8e37f94 FOREIGN KEY (queue_id) REFERENCES public.queues(id);


--
-- Name: team_memberships fk_rails_61c29b529e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT fk_rails_61c29b529e FOREIGN KEY (team_id) REFERENCES public.teams(id);


--
-- Name: audit_events fk_rails_6853c8fc2c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_6853c8fc2c FOREIGN KEY (ticket_id) REFERENCES public.tickets(id);


--
-- Name: outbox_events fk_rails_72689aebf9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT fk_rails_72689aebf9 FOREIGN KEY (ticket_id) REFERENCES public.tickets(id);


--
-- Name: customer_identities fk_rails_79d4b2c664; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_identities
    ADD CONSTRAINT fk_rails_79d4b2c664 FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: dead_letters fk_rails_7ee7c1307c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dead_letters
    ADD CONSTRAINT fk_rails_7ee7c1307c FOREIGN KEY (ticket_id) REFERENCES public.tickets(id);


--
-- Name: ai_turns fk_rails_82b05d2e53; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_turns
    ADD CONSTRAINT fk_rails_82b05d2e53 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: outbox_events fk_rails_8e81165da3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT fk_rails_8e81165da3 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: deliveries fk_rails_92b2b08057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT fk_rails_92b2b08057 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: handoff_summaries fk_rails_93ff00cebd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handoff_summaries
    ADD CONSTRAINT fk_rails_93ff00cebd FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: ai_turns fk_rails_ad9c9534a9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_turns
    ADD CONSTRAINT fk_rails_ad9c9534a9 FOREIGN KEY (ticket_id) REFERENCES public.tickets(id);


--
-- Name: audit_events fk_rails_b7193bfed1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_b7193bfed1 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: routing_rulesets fk_rails_b886984cf3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routing_rulesets
    ADD CONSTRAINT fk_rails_b886984cf3 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: routing_rulesets fk_rails_bc6d57a4e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routing_rulesets
    ADD CONSTRAINT fk_rails_bc6d57a4e7 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: tickets fk_rails_c6ad1a6fa1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tickets
    ADD CONSTRAINT fk_rails_c6ad1a6fa1 FOREIGN KEY (linked_ticket_id) REFERENCES public.tickets(id);


--
-- Name: queue_versions fk_rails_cdd8cbe585; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queue_versions
    ADD CONSTRAINT fk_rails_cdd8cbe585 FOREIGN KEY (queue_id) REFERENCES public.queues(id);


--
-- Name: queues fk_rails_d2652f34b4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues
    ADD CONSTRAINT fk_rails_d2652f34b4 FOREIGN KEY (team_id) REFERENCES public.teams(id);


--
-- Name: customers fk_rails_df42b7b625; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT fk_rails_df42b7b625 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: provider_accounts fk_rails_e0a8efeb27; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_accounts
    ADD CONSTRAINT fk_rails_e0a8efeb27 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: tickets fk_rails_ea25a37fb1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tickets
    ADD CONSTRAINT fk_rails_ea25a37fb1 FOREIGN KEY (assignee_id) REFERENCES public.users(id);


--
-- Name: deliveries fk_rails_ed71b29557; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT fk_rails_ed71b29557 FOREIGN KEY (ticket_id) REFERENCES public.tickets(id);


--
-- Name: queue_versions fk_rails_efffefcebd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queue_versions
    ADD CONSTRAINT fk_rails_efffefcebd FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: routing_rulesets fk_routing_rulesets_default_queue_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routing_rulesets
    ADD CONSTRAINT fk_routing_rulesets_default_queue_same_brand FOREIGN KEY (default_queue_id, brand_id) REFERENCES public.queues(id, brand_id);


--
-- Name: tickets fk_tickets_customer_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tickets
    ADD CONSTRAINT fk_tickets_customer_same_brand FOREIGN KEY (customer_id, brand_id) REFERENCES public.customers(id, brand_id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261123010000'),
('20261123000000'),
('20261122030000'),
('20261122015000'),
('20261122010000'),
('20261122000000'),
('20261121040000'),
('20261121030000'),
('20261121020000'),
('20261121010000'),
('20261121000000'),
('20261120010000'),
('20261120000000'),
('20261119010000'),
('20261119000000'),
('20261118190000'),
('20261118180000');

