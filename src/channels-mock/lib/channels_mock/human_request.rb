module ChannelsMock
  # Pedido de humano e aviso de transferência no simulador (ROADMAP 10; RN-34, RN-42, RF-43).
  #
  # O botão "Pedir humano" manda, pela mesma rota do chat, a frase que a política da plataforma reconhece no idioma
  # da marca da conta (Handoff::Policy: pt-BR na InfinitePay, inglês na JIM).
  #
  # O envio do provedor (contrato chat_send: customer_ref, text, reply_to) não diz quem escreveu a mensagem. Para
  # destacar o aviso de transferência, o simulador compara o texto com os avisos padrão da plataforma
  # (Handoff::Policy::DEFAULT, RN-42). É só apresentação do simulador: quando o aviso ficar configurável por marca
  # (bloco 12), o texto aqui precisa acompanhar, ou o contrato ganha um campo que diga o tipo da mensagem.
  module HumanRequest
    TEXTS = {
      "infinitepay-chat-mock" => "Quero falar com um atendente",
      "jim-chat-mock" => "I want to talk to a human agent"
    }.freeze

    TRANSFER_NOTICES = [
      "Estou te transferindo para um especialista. Ele já recebeu o histórico da nossa conversa.",
      "I'm transferring you to a specialist. They already have the history of our conversation."
    ].freeze

    module_function

    def text_for(account) = TEXTS.fetch(account, TEXTS.fetch("infinitepay-chat-mock"))
    def transfer_notice?(text) = TRANSFER_NOTICES.include?(text.to_s.strip)
  end
end
