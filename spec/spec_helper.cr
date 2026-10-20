# SPDX-License-Identifier: AGPL-3.0-or-later

ENV["MARTEN_ENV"] = "test"

require "spec"

# Composition d'une distribution : l'interface (qui charge le cœur), le
# métier de l'extension, son interface Bulma, puis les réglages.
require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-amortis"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"
# Migrations du cœur et de l'extension.
require "partiduo/cli"
require "../src/partiduo-amortis/cli"
# Branchement sur TELEDEC (A-AMO-2) : comme une distribution qui compose les
# deux extensions, le fichier d'enregistrement, les migrations et les
# applications de `partiduo-teledec`.
require "../src/partiduo-amortis/teledec"
require "partiduo-teledec/cli"
Marten.configure do |config|
  config.installed_apps = config.installed_apps + Teledec::INSTALLED_APPS
end

require "marten/spec"
require "marten_auth/spec"

# Comptes, navigateur et dossier de test de l'interface, créés par le
# contrat `Partiduo::Api` (DECISIONS D-SKEL-004 du squelette).
require "../lib/partiduo-ui-bulma/spec/support/accounts"
require "../lib/partiduo-ui-bulma/spec/support/browser"
require "../lib/partiduo-ui-bulma/spec/support/reference"
require "../lib/partiduo-ui-bulma/spec/support/books"

require "./support/**"

# Date du jour figée : les immobilisations d'exemple sont acquises en 2025
# et 2026, dans les exercices créés par les specs.
SPEC_NOW = Time.utc(2026, 9, 28, 10, 0, 0)
Partiduo::Config.clock = -> { SPEC_NOW }
