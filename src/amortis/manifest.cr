# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension des immobilisations et des amortissements
# (ADR-003 D2).
#
# * Dépendance : `ACCOUNTING` — les dotations, dépréciations et sorties
#   d'actif sont des écritures d'inventaire passées par le service
#   d'écriture du module, dans un journal d'opérations diverses.
# * Incompatibilité (ADR-011 A1) : `PERSO`, l'extension des finances d'un
#   foyer — un foyer n'amortit rien. Le type de dossier « foyer » n'est pas
#   un code du registre : il est refusé par le contrat (D-AMO-002,
#   amendement proposé A-AMO-1).
# * Permissions (D4) : `amortis.read` (registre, plans, états),
#   `amortis.write` (inscrire, modifier, déprécier, céder ; proposer et
#   passer les écritures, les extourner), `amortis.admin` (réglages,
#   comptes par défaut). Le contrat du cœur exige en plus ses propres
#   droits : `accounting.entry.post` pour passer une écriture,
#   `accounting.entry.cancel` pour l'extourner, `accounting.account.write`
#   pour créer un compte d'amortissement manquant (D-AMO-012).
# * Menu (D6 d'ADR-003) : rubrique « Immobilisations » entre la
#   Consultation et le Référentiel ; réglages sous « Paramètres ».
# * Abonnement : `entry.cancelled` — une écriture d'inventaire extournée,
#   ici ou dans la Comptabilité, rend ses montants à proposer (D-AMO-009).
Partiduo::Modules.register do
  code "AMORTIS"
  name "amortis.module.name"
  version Amortis::VERSION
  requires_core "~> 0.1"
  depends_on "ACCOUNTING"
  incompatible_with "PERSO"

  permission "amortis.read"
  permission "amortis.write"
  permission "amortis.admin"

  menu "AMORTIS", order: 45, permission: "amortis.read"
  menu "AMORTIS_ASSETS", parent: "AMORTIS", order: 10, route: "amortis:assets", permission: "amortis.read"
  menu "AMORTIS_POSTINGS", parent: "AMORTIS", order: 20, route: "amortis:postings", permission: "amortis.read"
  menu "AMORTIS_STATEMENTS", parent: "AMORTIS", order: 30, route: "amortis:statements", permission: "amortis.read"
  menu "AMORTIS_SETTINGS", parent: "SETTINGS", order: 95, route: "amortis:settings", permission: "amortis.admin"

  ui "bulma", path: "ui/bulma"

  on("entry.cancelled") { |event| Amortis::Subscriptions.entry_cancelled(event) }
end
