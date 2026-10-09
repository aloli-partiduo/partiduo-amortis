# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-amortis` : le métier de l'extension des
# immobilisations et des amortissements (manifeste, modèles, calcul des
# plans, écritures d'inventaire, états, contrat `Amortis::Api`), sans
# interface. L'interface Bulma est dans `ui/bulma/`, requise à part par la
# distribution : `require "partiduo-amortis/ui/bulma"`.
#
# La distribution ajoute ensuite `Amortis::INSTALLED_APPS` à ses
# applications Marten, et `require "partiduo-amortis/cli"` à sa ligne de
# commande (migrations).
require "partiduo"

require "./amortis/app"
