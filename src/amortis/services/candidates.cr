# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Acquisitions à inscrire (D-AMO-004) : lignes d'écritures des exercices
  # ouverts au débit d'un compte d'immobilisation, qu'aucune
  # immobilisation ne cite. Lues par le contrat de la Comptabilité avec les
  # droits de l'acteur (journaux visibles). Interne.
  module Candidates
    alias Acc = Partiduo::Api::Accounting
    alias Api = Amortis::Api

    # Écritures lues au plus (contrat de la Comptabilité).
    LIMIT = 500

    def self.list(actor : Partiduo::Api::Actor) : Array(Api::CandidateView)
      regime = Settings.regime
      open = Partiduo::Api::Core.fiscal_years(Records.system).reject(&.closed?).compact_map(&.starts_on)
      used = Asset.all.pluck(:entry_line_id).compact_map(&.first.try(&.as(Int64))).to_set
      query = Acc::EntryQuery.new(account: "2", account_prefix: true, date_from: open.min?, include_cancelled: false,
        limit: LIMIT)
      Acc.entries(actor, query).reject(&.reversal?).flat_map do |entry|
        entry.lines.select do |line|
          line.side.debit? && Accounts.asset_account?(regime, line.account_number) && !used.includes?(line.id)
        end.map do |line|
          Api::CandidateView.new(entry_id: entry.id, line_id: line.id, date: entry.date, ledger_code: entry.ledger_code,
            receipt: entry.receipt, label: line.label.presence || entry.label, account: line.account_number,
            account_label: line.account_label, amount: line.amount)
        end
      end
    rescue Partiduo::Api::AccessDenied
      [] of Api::CandidateView
    end

    def self.find(actor : Partiduo::Api::Actor, line_id : Int64) : Api::CandidateView?
      list(actor).find(&.line_id.==(line_id))
    end
  end
end
