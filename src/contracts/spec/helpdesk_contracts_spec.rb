RSpec.describe HelpdeskContracts do
  let(:outbound) { fixture("valid", :agent_outbound, "escalate_07_secao_5_3") }
  let(:inbound) { fixture("valid", :agent_inbound, "message_created_07_secao_5_2") }
  let(:normalized) { fixture("valid", :normalized_message, "whatsapp_07_secao_5_1") }

  def pointers(contract, payload)
    described_class.errors(contract, payload).map(&:pointer)
  end

  describe "RNF-28 / invariante 10: validação na entrada e na saída" do
    it "aceita os exemplos do 07" do
      expect(described_class.valid?(:normalized_message, normalized)).to be(true)
      expect(described_class.valid?(:agent_inbound, inbound)).to be(true)
      expect(described_class.valid?(:agent_outbound, outbound)).to be(true)
    end

    it "rejeita payload sem campo obrigatório e aponta o campo" do
      outbound.delete("conversation_id")

      errors = described_class.errors(:agent_outbound, outbound)

      expect(errors).not_to be_empty
      expect(errors.map(&:message).join).to include("conversation_id")
    end

    it "rejeita tipo errado" do
      inbound["context_until_seq"] = "5"

      expect(pointers(:agent_inbound, inbound)).to include("/context_until_seq")
    end

    it "rejeita formato de data inválido" do
      normalized["received_at"] = "17/11/2026"

      expect(pointers(:normalized_message, normalized)).to include("/received_at")
    end

    it "aceita JSON em texto e rejeita JSON malformado" do
      expect(described_class.valid?(:agent_outbound, JSON.generate(outbound))).to be(true)

      errors = described_class.errors(:agent_outbound, "{ nao e json")

      expect(errors.map(&:type)).to eq([ "json_invalido" ])
    end

    it "aceita chaves em símbolo" do
      symbolized = JSON.parse(JSON.generate(outbound), symbolize_names: true)

      expect(described_class.valid?(:agent_outbound, symbolized)).to be(true)
    end

    it "rejeita payload que não é objeto" do
      expect(described_class.valid?(:agent_outbound, [ outbound ])).to be(false)
    end
  end

  describe "RNF-28 / 07 seção 5.4: versão pelo campo schema" do
    it "rejeita versão desconhecida no campo schema" do
      outbound["schema"] = "helpdesk.agent_action.v9"

      errors = described_class.errors(:agent_outbound, outbound)

      expect(errors.map(&:type)).to include("schema_desconhecido")
      expect(errors.map(&:pointer)).to include("/schema")
    end

    it "rejeita schema de outro contrato" do
      outbound["schema"] = "helpdesk.agent_event.v1"

      expect(described_class.errors(:agent_outbound, outbound).map(&:type)).to include("schema_de_outro_contrato")
    end

    it "rejeita payload sem o campo schema nos contratos que o exigem" do
      outbound.delete("schema")

      expect(pointers(:agent_outbound, outbound)).not_to be_empty
    end

    it "rejeita versão pedida por argumento que não existe" do
      expect(described_class.errors(:whatsapp_webhook, {}, version: "v7").map(&:type)).to eq([ "schema_desconhecido" ])
    end

    it "rejeita quando a versão do argumento diverge da do campo schema" do
      outbound["schema"] = "helpdesk.agent_action.v1"

      expect(described_class.errors(:agent_outbound, outbound, version: "v2").map(&:type)).to include("schema_desconhecido")
    end

    it "lista as versões disponíveis" do
      expect(described_class.versions).to eq([ "v1" ])
    end

    it "descobre o contrato pelo campo schema" do
      expect(described_class.contract_for(outbound)).to eq(:agent_outbound)
      expect(described_class.contract_for(inbound)).to eq(:agent_inbound)
      expect(described_class.contract_for(normalized)).to eq(:normalized_message)
      expect(described_class.contract_for("schema" => "helpdesk.refund.v1")).to be_nil
    end

    it "levanta ArgumentError para contrato que não existe (erro de programação, não de payload)" do
      expect { described_class.valid?(:refund, {}) }.to raise_error(ArgumentError, /refund/)
    end
  end

  describe "07 seção 5.4: campo novo opcional não quebra o consumidor" do
    it "aceita campo extra na raiz e em objetos aninhados" do
      outbound["campo_novo"] = "x"
      outbound["agent"]["campo_novo"] = 1
      inbound["context"]["campo_novo"] = []
      normalized["sender"]["campo_novo"] = true

      expect(described_class.valid?(:agent_outbound, outbound)).to be(true)
      expect(described_class.valid?(:agent_inbound, inbound)).to be(true)
      expect(described_class.valid?(:normalized_message, normalized)).to be(true)
    end
  end

  describe "RN-35 / invariante 11: a IA só faz o que o contrato permite" do
    { "reply" => { "reply" => { "text" => "Seu repasse cai hoje." } },
      "escalate" => {},
      "resolve" => { "resolution" => { "reason" => "duvida_respondida" } } }.each do |action, content|
      it "aceita a ação #{action} com o seu conteúdo" do
        outbound["action"] = action
        outbound.merge!(content)

        expect(described_class.valid?(:agent_outbound, outbound)).to be(true)
      end
    end

    %w[refund update_customer change_bank_account increase_limit tool_calls].each do |action|
      it "rejeita a ação #{action}" do
        outbound["action"] = action

        expect(pointers(:agent_outbound, outbound)).to include("/action")
      end
    end

    it "rejeita a ação ausente" do
      outbound.delete("action")

      expect(described_class.valid?(:agent_outbound, outbound)).to be(false)
    end

    it "rejeita tool_call sem o nome da ferramenta" do
      outbound["tool_calls"].first.delete("tool")

      expect(described_class.valid?(:agent_outbound, outbound)).to be(false)
    end

    it "RN-39: escalate exige os cinco campos do resumo" do
      %w[problema dados_cliente acoes_tomadas motivo pendente].each do |field|
        payload = fixture("valid", :agent_outbound, "escalate_07_secao_5_3")
        payload["escalation"]["summary"].delete(field)

        expect(described_class.valid?(:agent_outbound, payload)).to be(false), "aceitou sem #{field}"
      end
    end

    it "RF-38 / RN-37: toda ação traz modelo e versão do agente" do
      outbound["agent"].delete("version")

      expect(described_class.valid?(:agent_outbound, outbound)).to be(false)
    end
  end

  describe "RN-56: correlação da ação com o turno" do
    %w[in_reply_to turn context_until_seq assignment_version].each do |field|
      it "rejeita ação sem #{field}" do
        outbound.delete(field)

        expect(described_class.valid?(:agent_outbound, outbound)).to be(false)
      end
    end

    it "rejeita in_reply_to que não é UUID" do
      outbound["in_reply_to"] = "turno-2"

      expect(pointers(:agent_outbound, outbound)).to include("/in_reply_to")
    end

    it "rejeita turno menor que 1" do
      outbound["turn"] = 0

      expect(pointers(:agent_outbound, outbound)).to include("/turn")
    end

    %w[turn context_until_seq assignment_version deadline_at event_id].each do |field|
      it "rejeita evento de entrada sem #{field}" do
        inbound.delete(field)

        expect(described_class.valid?(:agent_inbound, inbound)).to be(false)
      end
    end
  end

  describe "Invariante 6: marca obrigatória nos contratos que a carregam" do
    it "rejeita mensagem normalizada sem brand" do
      normalized.delete("brand")

      expect(described_class.valid?(:normalized_message, normalized)).to be(false)
    end

    it "rejeita evento de entrada sem brand" do
      inbound.delete("brand")

      expect(described_class.valid?(:agent_inbound, inbound)).to be(false)
    end

    it "rejeita brand vazia ou fora do formato de slug" do
      [ "", "Infinite Pay", 1 ].each do |brand|
        inbound["brand"] = brand

        expect(pointers(:agent_inbound, inbound)).to include("/brand"), "aceitou #{brand.inspect}"
      end
    end
  end

  describe ".validate!" do
    it "devolve o payload quando é válido" do
      expect(described_class.validate!(:agent_outbound, outbound)).to eq(outbound)
    end

    it "levanta InvalidPayload com a lista de violações" do
      outbound["action"] = "refund"
      outbound.delete("turn")

      expect { described_class.validate!(:agent_outbound, outbound) }.to raise_error(HelpdeskContracts::InvalidPayload) { |error|
        expect(error.contract).to eq(:agent_outbound)
        expect(error.violations.map(&:pointer)).to include("/action")
        expect(error.violations.size).to be >= 2
        expect(error.message).to include("agent_outbound", "/action")
      }
    end

    it "não muta o payload recebido" do
      frozen = JSON.parse(JSON.generate(outbound)).freeze

      expect { described_class.validate!(:agent_outbound, frozen) }.not_to raise_error
    end
  end

  describe "RNF-28: violação de campo obrigatório aponta o campo que falta" do
    it "usa o pointer do campo ausente, não o do objeto pai" do
      outbound.delete("conversation_id")
      outbound["agent"].delete("version")

      errors = described_class.errors(:agent_outbound, outbound)

      expect(errors.map { |e| [ e.pointer, e.type ] }).to include([ "/conversation_id", "required" ], [ "/agent/version", "required" ])
    end

    it "gera uma violação por campo ausente" do
      outbound.delete("turn")
      outbound.delete("in_reply_to")

      expect(pointers(:agent_outbound, outbound)).to include("/turn", "/in_reply_to")
    end

    it "escapa ~ e / no nome do campo (RFC 6901)" do
      schemer = JSONSchemer.schema({ "required" => [ "a/b~c" ] })
      error = schemer.validate({}).first

      expect(described_class.send(:to_violations, error).map(&:pointer)).to eq([ "/a~1b~0c" ])
    end
  end

  describe "Invariante 6 / 07 seção 5.3: brand na ação do agente" do
    it "rejeita ação sem brand" do
      outbound.delete("brand")

      expect(pointers(:agent_outbound, outbound)).to include("/brand")
    end

    it "rejeita brand fora do formato de slug, como na entrada" do
      [ "", "Infinite Pay", 1 ].each do |brand|
        outbound["brand"] = brand

        expect(pointers(:agent_outbound, outbound)).to include("/brand"), "aceitou #{brand.inspect}"
      end
    end

    it "usa o mesmo formato de brand do agent_inbound" do
      schemas = %w[agent_inbound agent_outbound].map do |name|
        JSON.parse(File.read(File.expand_path("../v1/schemas/#{name}.json", __dir__), encoding: "UTF-8"))
      end

      expect(schemas[0]["$defs"]["brand"]).to eq(schemas[1]["$defs"]["brand"])
    end
  end

  describe "RF-48 / 07 seção 5.3: cada ação leva o seu conteúdo" do
    let(:reply) { fixture("valid", :agent_outbound, "reply") }
    let(:resolve) { fixture("valid", :agent_outbound, "resolve_sem_tool_calls") }

    it "reply exige reply" do
      reply.delete("reply")

      expect(pointers(:agent_outbound, reply)).to include("/reply")
    end

    it "reply exige reply.text" do
      reply["reply"].delete("text")

      expect(pointers(:agent_outbound, reply)).to include("/reply/text")
    end

    it "reply rejeita texto vazio ou que não é texto" do
      [ "", 42, nil ].each do |text|
        reply["reply"]["text"] = text

        expect(pointers(:agent_outbound, reply)).to include("/reply/text"), "aceitou #{text.inspect}"
      end
    end

    it "resolve exige resolution.reason" do
      resolve["resolution"].delete("reason")

      expect(pointers(:agent_outbound, resolve)).to include("/resolution/reason")
    end

    it "resolve exige resolution" do
      resolve.delete("resolution")

      expect(pointers(:agent_outbound, resolve)).to include("/resolution")
    end

    it "resolve aceita resolution.text opcional" do
      resolve["resolution"]["text"] = "Fico à disposição."

      expect(described_class.valid?(:agent_outbound, resolve)).to be(true)
    end

    it "escalate não exige reply nem resolution" do
      expect(outbound).not_to include("reply", "resolution")
      expect(described_class.valid?(:agent_outbound, outbound)).to be(true)
    end
  end

  describe "RF-03 / 07 seção 5.1: assunto e anexos do e-mail na mensagem normalizada" do
    let(:email) { fixture("valid", :normalized_message, "email_com_assunto_e_anexo") }

    it "aceita subject e attachments opcionais" do
      expect(described_class.valid?(:normalized_message, email)).to be(true)
      expect(described_class.valid?(:normalized_message, normalized)).to be(true)
    end

    %w[filename content_type size_bytes].each do |field|
      it "rejeita anexo sem #{field}" do
        email["content"]["attachments"].first.delete(field)

        expect(pointers(:normalized_message, email)).to include("/content/attachments/0/#{field}")
      end
    end

    it "rejeita tamanho negativo e subject que não é texto" do
      email["content"]["attachments"].first["size_bytes"] = -1
      email["content"]["subject"] = 1

      expect(pointers(:normalized_message, email)).to include("/content/attachments/0/size_bytes", "/content/subject")
    end
  end

  describe "RF-01 a RF-03 / ADR-018: webhooks de entrada no formato dos provedores" do
    let(:whatsapp) { fixture("valid", :whatsapp_webhook, "mensagem_de_texto") }
    let(:value) { whatsapp["entry"][0]["changes"][0]["value"] }
    let(:value_pointer) { "/entry/0/changes/0/value" }

    it "valida o formato de cada provedor sem campo schema, pela versão do argumento" do
      expect(described_class.valid?(:chat_webhook, fixture("valid", :chat_webhook, "texto"), version: "v1")).to be(true)
      expect(described_class.valid?(:whatsapp_webhook, whatsapp)).to be(true)
      expect(described_class.valid?(:email_push, fixture("valid", :email_push, "notificacao"))).to be(true)
      expect(described_class.valid?(:email_message, fixture("valid", :email_message, "com_anexo"))).to be(true)
    end

    it "WhatsApp: exige o envelope da Cloud API" do
      whatsapp["object"] = "page"
      value["messaging_product"] = "messenger"

      expect(pointers(:whatsapp_webhook, whatsapp)).to include("/object", "#{value_pointer}/messaging_product")
    end

    it "WhatsApp: metadata.phone_number_id identifica a conta" do
      value["metadata"].delete("phone_number_id")

      expect(pointers(:whatsapp_webhook, whatsapp)).to include("#{value_pointer}/metadata/phone_number_id")
    end

    it "WhatsApp: aceita status de entrega sem messages" do
      expect(described_class.valid?(:whatsapp_webhook, fixture("valid", :whatsapp_webhook, "status_delivered"))).to be(true)
    end

    it "WhatsApp: rejeita value sem messages e sem statuses" do
      value.delete("messages")

      expect(pointers(:whatsapp_webhook, whatsapp)).to include("#{value_pointer}/messages", "#{value_pointer}/statuses")
    end

    it "WhatsApp: rejeita value com messages e statuses ao mesmo tempo" do
      value["statuses"] = fixture("valid", :whatsapp_webhook, "status_delivered")["entry"][0]["changes"][0]["value"]["statuses"]

      expect(described_class.errors(:whatsapp_webhook, whatsapp).map { |e| [ e.pointer, e.type ] }).to include([ value_pointer, "oneOf" ])
    end

    it "WhatsApp: aceita mensagem que não é texto (o adaptador decide o que fazer)" do
      %w[image reaction interactive].each do |type|
        message = value["messages"][0]
        message["type"] = type
        message.delete("text")

        expect(described_class.valid?(:whatsapp_webhook, whatsapp)).to be(true), "rejeitou #{type}"
      end
    end

    it "WhatsApp: aceita imagem e lote com texto e imagem" do
      expect(described_class.valid?(:whatsapp_webhook, fixture("valid", :whatsapp_webhook, "mensagem_de_imagem"))).to be(true)
      expect(described_class.valid?(:whatsapp_webhook, fixture("valid", :whatsapp_webhook, "lote_texto_e_imagem"))).to be(true)
    end

    it "WhatsApp: type=text exige text.body" do
      value["messages"][0].delete("text")

      expect(pointers(:whatsapp_webhook, whatsapp)).to include("#{value_pointer}/messages/0/text")
    end

    it "WhatsApp: rejeita type vazio ou que não é texto" do
      [ "", 1 ].each do |type|
        value["messages"][0]["type"] = type

        expect(pointers(:whatsapp_webhook, whatsapp)).to include("#{value_pointer}/messages/0/type"), "aceitou #{type.inspect}"
      end
    end

    it "WhatsApp: rejeita status fora de sent, delivered, read e failed" do
      status = fixture("valid", :whatsapp_webhook, "status_delivered")
      status["entry"][0]["changes"][0]["value"]["statuses"][0]["status"] = "deleted"

      expect(pointers(:whatsapp_webhook, status)).to include("#{value_pointer}/statuses/0/status")
    end

    it "WhatsApp: contacts e profile.name são opcionais" do
      value.delete("contacts")

      expect(described_class.valid?(:whatsapp_webhook, whatsapp)).to be(true)
    end

    it "Gmail push: valida o conteúdo base64 do envelope do Pub/Sub" do
      push = fixture("valid", :email_push, "notificacao")
      push["message"]["data"] = [ JSON.generate("emailAddress" => "support@jim.example") ].pack("m0")

      errors = described_class.errors(:email_push, push)

      expect(errors.map { |e| [ e.pointer, e.type ] }).to include([ "/message/data/historyId", "required" ])
    end

    it "Gmail push: rejeita data que não decodifica para JSON" do
      push = fixture("valid", :email_push, "notificacao")
      push["message"]["data"] = [ "nao e json" ].pack("m0")

      expect(described_class.errors(:email_push, push).map(&:type)).to include("conteudo_invalido")
    end

    it "Gmail push: aceita historyId como número ou texto numérico" do
      push = fixture("valid", :email_push, "notificacao")
      push["message"]["data"] = [ JSON.generate("emailAddress" => "a@b.example", "historyId" => 98) ].pack("m0")

      expect(described_class.valid?(:email_push, push)).to be(true)
    end

    it "Gmail: exige From e Message-ID nos cabeçalhos" do
      %w[From Message-ID].each do |name|
        message = fixture("valid", :email_message, "com_anexo")
        message["payload"]["headers"].reject! { |h| h["name"] == name }

        expect(pointers(:email_message, message)).to include("/payload/headers"), "aceitou sem #{name}"
      end
    end

    it "Gmail: To e Subject são opcionais (07, seção 5.1)" do
      message = fixture("valid", :email_message, "com_anexo")
      message["payload"]["headers"].reject! { |h| %w[To Subject].include?(h["name"]) }

      expect(described_class.valid?(:email_message, message)).to be(true)
      expect(described_class.valid?(:email_message, fixture("valid", :email_message, "sem_subject_e_sem_to"))).to be(true)
    end

    it "Gmail: compara os nomes de cabeçalho sem diferenciar maiúsculas" do
      message = fixture("valid", :email_message, "com_anexo")
      message["payload"]["headers"].each { |h| h["name"] = h["name"].swapcase }

      expect(described_class.valid?(:email_message, message)).to be(true)
    end

    it "Gmail: nome de cabeçalho parecido não conta como Message-ID" do
      message = fixture("valid", :email_message, "com_anexo")
      message["payload"]["headers"].find { |h| h["name"] == "Message-ID" }["name"] = "X-Message-ID"

      expect(pointers(:email_message, message)).to include("/payload/headers")
    end

    it "Gmail: anexo só como metadados (filename, mimeType, body.size)" do
      message = fixture("valid", :email_message, "com_anexo")
      message["payload"]["parts"][1]["body"].delete("size")

      expect(pointers(:email_message, message)).to include("/payload/parts/1/body/size")
    end
  end

  describe "07 seção 5.0 / ADR-018: chamadas de saída aos provedores" do
    it "aceita uma chamada válida de cada canal" do
      expect(described_class.valid?(:whatsapp_send, fixture("valid", :whatsapp_send, "texto"))).to be(true)
      expect(described_class.valid?(:email_send, fixture("valid", :email_send, "resposta_na_thread"))).to be(true)
      expect(described_class.valid?(:chat_send, fixture("valid", :chat_send, "texto"))).to be(true)
    end

    it "WhatsApp: texto de até 4.096 caracteres" do
      send = fixture("valid", :whatsapp_send, "texto")
      send["text"]["body"] = "a" * 4096
      expect(described_class.valid?(:whatsapp_send, send)).to be(true)

      send["text"]["body"] = "a" * 4097
      expect(pointers(:whatsapp_send, send)).to include("/text/body")
    end

    it "Gmail: raw em base64url e threadId obrigatórios" do
      send = fixture("valid", :email_send, "resposta_na_thread")
      send["raw"] = "a+b/c="
      send.delete("threadId")

      expect(pointers(:email_send, send)).to include("/raw", "/threadId")
    end
  end

  describe "RNF-28: pattern com regex ECMA (^ e $ ancoram o valor inteiro)" do
    it "rejeita quebra de linha antes ou depois de um valor válido" do
      [ "infinitepay\n", "\ninfinitepay", "infinitepay\njim" ].each do |brand|
        outbound["brand"] = brand

        expect(pointers(:agent_outbound, outbound)).to include("/brand"), "aceitou #{brand.inspect}"
      end
    end

    it "rejeita trace_id, from do WhatsApp e raw do Gmail com quebra de linha" do
      normalized["trace_id"] = "4bf92f3577b34da6a3ce929d0e0e4736\n"
      whatsapp = fixture("valid", :whatsapp_webhook, "mensagem_de_texto")
      whatsapp["entry"][0]["changes"][0]["value"]["messages"][0]["from"] = "5511900000021\n"
      email = fixture("valid", :email_send, "resposta_na_thread")
      email["raw"] = "#{email['raw']}\n"

      expect(pointers(:normalized_message, normalized)).to include("/trace_id")
      expect(pointers(:whatsapp_webhook, whatsapp)).to include("/entry/0/changes/0/value/messages/0/from")
      expect(pointers(:email_send, email)).to include("/raw")
    end
  end

  describe "RF-48 / 07 seção 5.3: conteúdo da ação não pode ser só espaços" do
    it "rejeita reply.text só com espaços" do
      reply = fixture("valid", :agent_outbound, "reply")
      [ " ", "\n\t " ].each do |text|
        reply["reply"]["text"] = text

        expect(pointers(:agent_outbound, reply)).to include("/reply/text"), "aceitou #{text.inspect}"
      end
    end

    it "rejeita resolution.reason e resolution.text só com espaços" do
      resolve = fixture("valid", :agent_outbound, "resolve_com_texto_07_secao_5_3")
      resolve["resolution"] = { "reason" => "  ", "text" => " \n" }

      expect(pointers(:agent_outbound, resolve)).to include("/resolution/reason", "/resolution/text")
    end

    it "aceita texto com espaço em volta" do
      reply = fixture("valid", :agent_outbound, "reply")
      reply["reply"]["text"] = "  Seu repasse cai hoje.  "

      expect(described_class.valid?(:agent_outbound, reply)).to be(true)
    end
  end

  describe "RNF-28: corpo com UTF-8 inválido vira json_invalido, sem exceção" do
    it "rejeita corpo bruto com bytes \\xff" do
      body = "{\"brand\":\"\xff\"}".b

      expect(described_class.errors(:agent_outbound, body).map(&:type)).to eq([ "json_invalido" ])
    end

    it "lê como UTF-8 o corpo marcado como US-ASCII com bytes não ASCII" do
      body = JSON.generate(outbound.merge("brand" => "infinitepay", "campo" => "não")).dup.force_encoding("US-ASCII")

      expect(described_class.errors(:agent_outbound, body)).to eq([])
    end

    it "rejeita corpo US-ASCII com bytes que não formam UTF-8" do
      body = "{\"a\":\"\xc3\x28\"}".dup.force_encoding("US-ASCII")

      expect(described_class.errors(:agent_outbound, body).map(&:type)).to eq([ "json_invalido" ])
    end

    it "rejeita Hash com string em UTF-8 inválido" do
      outbound["reply"] = { "text" => "\xff".dup.force_encoding("UTF-8") }

      expect(described_class.errors(:agent_outbound, outbound).map(&:type)).to eq([ "json_invalido" ])
    end

    it "não deixa EncodingError escapar de validate!" do
      expect { described_class.validate!(:agent_outbound, "\xff".b) }.to raise_error(HelpdeskContracts::InvalidPayload)
    end
  end

  describe "07 seção 5.0: status e respostas dos provedores" do
    it "aceita status do chat, resposta do envio do WhatsApp e history.list do Gmail" do
      expect(described_class.valid?(:chat_status, fixture("valid", :chat_status, "delivered"))).to be(true)
      expect(described_class.valid?(:whatsapp_send_response, fixture("valid", :whatsapp_send_response, "texto_aceito"))).to be(true)
      expect(described_class.valid?(:email_history, fixture("valid", :email_history, "mensagem_nova"))).to be(true)
      expect(described_class.valid?(:email_history, fixture("valid", :email_history, "sem_history"))).to be(true)
    end

    it "chat: status só em sent, delivered, read e failed" do
      status = fixture("valid", :chat_status, "delivered")
      status["status"] = "lido"

      expect(pointers(:chat_status, status)).to include("/status")
    end

    it "WhatsApp: resposta do envio traz messages[0].id" do
      response = fixture("valid", :whatsapp_send_response, "texto_aceito")
      response["messages"] = []

      expect(pointers(:whatsapp_send_response, response)).to include("/messages")
    end

    it "Gmail: messagesAdded traz message.id e message.threadId" do
      history = fixture("valid", :email_history, "mensagem_nova")
      history["history"][0]["messagesAdded"][0]["message"].delete("threadId")

      expect(pointers(:email_history, history)).to include("/history/0/messagesAdded/0/message/threadId")
    end
  end
end
