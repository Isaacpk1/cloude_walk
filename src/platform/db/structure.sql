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
-- Name: queue_versions_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_versions_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'versão de fila é imutável (RN-20): crie uma versão nova';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

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
    updated_at timestamp(6) without time zone NOT NULL
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
-- Name: queue_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queue_versions ALTER COLUMN id SET DEFAULT nextval('public.queue_versions_id_seq'::regclass);


--
-- Name: queues id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues ALTER COLUMN id SET DEFAULT nextval('public.queues_id_seq'::regclass);


--
-- Name: team_memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships ALTER COLUMN id SET DEFAULT nextval('public.team_memberships_id_seq'::regclass);


--
-- Name: teams id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams ALTER COLUMN id SET DEFAULT nextval('public.teams_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


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
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


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
-- Name: index_queues_on_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_queues_on_team_id ON public.queues USING btree (team_id);


--
-- Name: index_queues_one_default_per_brand; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_queues_one_default_per_brand ON public.queues USING btree (brand_id) WHERE is_default;


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
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: queue_versions queue_versions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER queue_versions_immutable BEFORE DELETE OR UPDATE ON public.queue_versions FOR EACH ROW EXECUTE FUNCTION public.queue_versions_immutable();


--
-- Name: customer_identities fk_customer_identities_same_brand; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_identities
    ADD CONSTRAINT fk_customer_identities_same_brand FOREIGN KEY (customer_id, brand_id) REFERENCES public.customers(id, brand_id);


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
-- Name: teams fk_rails_5545c98c48; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT fk_rails_5545c98c48 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: team_memberships fk_rails_5aba9331a7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT fk_rails_5aba9331a7 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: team_memberships fk_rails_61c29b529e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_memberships
    ADD CONSTRAINT fk_rails_61c29b529e FOREIGN KEY (team_id) REFERENCES public.teams(id);


--
-- Name: customer_identities fk_rails_79d4b2c664; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_identities
    ADD CONSTRAINT fk_rails_79d4b2c664 FOREIGN KEY (customer_id) REFERENCES public.customers(id);


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
-- Name: queue_versions fk_rails_efffefcebd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queue_versions
    ADD CONSTRAINT fk_rails_efffefcebd FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261118190000'),
('20261118180000');

