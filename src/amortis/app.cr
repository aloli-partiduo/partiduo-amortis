# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/**"
require "./services/calendar"
require "./services/**"
require "./api/**"
require "./initial_data"

# Extension des immobilisations et des amortissements de Partiduo (ADR-003,
# ADR-007 D6) : registre des immobilisations et de leurs composants, plans
# d'amortissement comptable et fiscal (linéaire, dégressif, prorata
# temporis), amortissement dérogatoire, dépréciations, cession et mise au
# rebut ; écritures d'inventaire *proposées* puis passées par
# `Partiduo::Api::Accounting.post_entry`, annulables par extourne ; états
# des immobilisations et des amortissements (2054, 2055, registre de la
# 2035, état belge). Même plan qu'une application du cœur (DECISIONS C1 du
# cœur) : `manifest.cr`, `models/`, `migrations/`, `services/` (internes),
# `api/` (contrat public `Amortis::Api`), `locales/`.
module Amortis
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Code du registre (ADR-003 D2) : `amortis` dans `PARTIDUO_MODULES`.
  CODE = "AMORTIS"

  # Application Marten du métier : modèles (tables `amortis_*`), migrations
  # et libellés.
  class App < Marten::App
    label "amortis"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS`.
  INSTALLED_APPS = [Amortis::App] of Marten::Apps::Config.class
end

# Immobilisations de la 2035 (A-AMO-3, D-AMO-018) : un professionnel libéral
# qui tient la Comptabilité et l'extension voit sa 2035 préparée avec les
# plans de l'extension (dégressif, composants, cessions) au lieu du registre
# linéaire du module `liberal`. Accroche du cœur : le bloc n'est appelé que
# si `AMORTIS` est actif, avec l'acteur système.
Partiduo::Api::Liberal.register_asset_source(Amortis::CODE) do |actor, year|
  Amortis::Api.liberal_assets(actor, year)
end
