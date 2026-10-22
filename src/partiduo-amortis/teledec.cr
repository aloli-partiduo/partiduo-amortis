# SPDX-License-Identifier: AGPL-3.0-or-later

# Branchement de l'extension sur `partiduo-teledec` (A-AMO-2, D-AMO-017,
# D-AMO-021) : les annexes 2054 et 2055 de la liasse du régime réel normal
# et le tableau 2033-C du régime simplifié sont fournis à TELEDEC, qui joint
# ceux du régime de la liasse au bloc `zones_formulaires` de l'API Balance.
# Fichier à part, sur le modèle de `partiduo-amortis/ui/bulma` : le métier
# de l'extension ne dépend pas de `partiduo-teledec` ; la distribution qui
# compose les deux extensions ajoute
#
#   require "partiduo-amortis/teledec"
#
# après `require "partiduo-amortis"` et `require "partiduo-teledec"`.
# TELEDEC n'appelle le bloc que si `AMORTIS` est actif et que le régime de
# la liasse a ces formulaires.
require "partiduo-teledec"
require "../partiduo-amortis"

Teledec::Api.register_annexes(Amortis::CODE, %w[2054 2055 2033-C]) do |actor, fiscal_year_id|
  Amortis::Api.liasse_annexes(actor, fiscal_year_id)
end
