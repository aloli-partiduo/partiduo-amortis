# SPDX-License-Identifier: AGPL-3.0-or-later

# Données initiales d'un dossier d'entreprise neuf, l'extension active
# (ADR-001 D2, convention C6) : comptes de l'inventaire des immobilisations
# absents du plan de base (dotations, reprises, dérogatoires, cessions),
# après le plan comptable de la Comptabilité. Rien pour un foyer.
Partiduo::Api::InitialData.register(Amortis::CODE, "accounts", order: 200,
  kinds: [Partiduo::Api::InitialData::COMPANY]) do |context|
  Amortis::Accounts.ensure_defaults(context.actor, context.tax_regime, context.locale)
end
