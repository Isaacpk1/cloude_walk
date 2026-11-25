// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Mostra a barra de progresso logo no começo da troca de tela (padrão: 500 ms de espera).
window.Turbo?.setProgressBarDelay?.(80)
