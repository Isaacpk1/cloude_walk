# Horário do painel: um fuso e um formato só, para a tela e para os textos montados nos read models
# (linha do tempo, recusa do turno). O PanelHelper#panel_time usa o mesmo.
module PanelClock
  TIME_ZONE = "America/Sao_Paulo".freeze

  module_function

  def format(time, precise: false)
    time.in_time_zone(TIME_ZONE).strftime(precise ? "%d/%m/%Y %H:%M:%S.%L" : "%d/%m/%Y %H:%M:%S")
  end
end
