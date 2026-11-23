# Fila humana (ROADMAP 10; RF-42, RF-45, RN-29): lê só pelo HumanQueue. ?marca=<slug> restringe à marca (invariante 6).
class HumanQueueController < PanelController
  rescue_from HumanQueue::NotFound do
    render "human_queue/not_found", status: :not_found
  end

  def index
    @queue = HumanQueue.new(brand_slug: params[:marca])
    @entries = @queue.entries
    @capacity = AnalystCapacity.new(brand: @queue.brand)
    @now = Time.current
  end
end
