# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Abonnés des événements du cœur (ADR-003 D7), appelés dans la transaction
  # de l'opération, l'extension active. Interne.
  module Subscriptions
    # `entry.cancelled` (D-AMO-009) : une écriture d'inventaire est
    # extournée, depuis l'extension ou depuis la Comptabilité — elle est
    # marquée annulée ; ses montants redeviennent à proposer et les champs
    # du plan de ses immobilisations se libèrent.
    def self.entry_cancelled(event : Partiduo::Events::Event) : Nil
      entry_id = event["entry_id"].to_i64
      reversal = event["reversal_entry_id"]?.try(&.to_i64?)
      Posting.filter(entry_id: entry_id, status: "posted")
        .update(status: "cancelled", reversal_entry_id: reversal || entry_id, updated_at: Time.utc)
    end
  end
end
