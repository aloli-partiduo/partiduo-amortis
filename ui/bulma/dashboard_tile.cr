# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  module Ui
    # Tuile « Immobilisations » des tableaux de bord du dossier :
    # immobilisations en service, valeur nette comptable, acquisitions à
    # inscrire. Rien si le registre est vide et qu'aucune acquisition
    # n'attend, si l'extension est inactive ou l'acteur sans droit.
    module Tile
      def self.for(actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) : PartiduoUi::Dashboard::Tile?
        view = Api.tile(actor) || return
        return if view.in_service_count.zero? && view.candidate_count.zero?
        alert = view.candidate_count.zero? ? nil : I18n.t("amortis_ui.tile.candidates", count: view.candidate_count)
        PartiduoUi::Dashboard::Tile.new(Amortis::CODE, I18n.t("amortis_ui.tile.label"), view.in_service_count.to_s,
          sub: I18n.t("amortis_ui.tile.sub", amount: fmt.amount(view.net_value)), alert: alert, url: Ui.url("assets"))
      end
    end
  end
end

# Point d'accroche de l'interface commune (`PartiduoUi::Extensions.tile`) :
# appelé seulement quand l'extension est active.
PartiduoUi::Extensions.tile Amortis::CODE do |actor, fmt|
  Amortis::Ui::Tile.for(actor, fmt).try { |tile| [tile] } || [] of PartiduoUi::Dashboard::Tile
end
