# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Annexes 2054 (immobilisations) et 2055 (amortissements) de la liasse du
  # régime réel normal, en zones de TELEDEC (A-AMO-2, D-AMO-017) : rubriques
  # de l'état de l'exercice (`Statements.statement`, D-AMO-013) → zones des
  # formulaires, par une table datée par millésime, comme la table de la
  # 2035 du module `liberal`. Montants arrondis à l'euro ligne par ligne,
  # totaux recalculés sur les lignes arrondies ; zones nulles omises.
  #
  # Ce module ne connaît pas l'extension TELEDEC : il rend des cases, que
  # `src/partiduo-amortis/teledec.cr` fournit à `Teledec::Api` quand la
  # distribution les compose. Interne ; contrat : `Api.liasse_annexes`.
  module Annexes
    alias D = BigDecimal

    # Zones d'une rubrique : 2054 (brut au début, augmentations,
    # diminutions par cession ou mise hors service, brut à la fin), 2055
    # cadre A (amortissements au début, dotations, diminutions, à la fin),
    # 2055 cadre B (dérogatoires : dotations différentiel de durée, mode
    # dégressif ; reprises différentiel de durée, mode dégressif ; mouvement
    # net). Chaîne vide : pas de zone.
    record Line, gross : {String, String, String, String}, depreciation : {String, String, String, String}? = nil,
      derogatory : {String, String, String, String, String}? = nil

    # Table d'un millésime : ligne de chaque rubrique (`Rubrics::FR`), lignes de
    # total (incorporelles, corporelles, financières, général) et rubriques
    # qu'elles réunissent.
    record Table, rubrics : Hash(String, Line), totals : Array({Line, Array(String)})

    INTANGIBLE = %w[establishment intangible]
    TANGIBLE   = %w[land building_own building_other building_fittings technical general_fittings transport office
      other_tangible in_progress advances]
    FINANCIAL = %w[participations securities loans]

    # Millésime 2023 (fichiers `2054.xlsx` et `2055.xlsx` de la base de
    # connaissances de TELEDEC, dernière version publiée ; relevé dans
    # `partiduo-docs/travail/teledec/FORMULAIRES-TELEDEC.adoc`). Les
    # terrains n'ont pas d'amortissement mais ont leurs zones ; les
    # immobilisations en cours, les avances et les immobilisations
    # financières n'en ont pas dans la 2055. Pas de ligne propre au fonds
    # commercial : il reste dans « autres immobilisations incorporelles »
    # (rubrique `intangible`).
    TABLE_2023 = Table.new(
      rubrics: {
        "establishment"     => Line.new({"RT", "RV", "RX", "RY"}, {"UR", "US", "UT", "UU"}, {"BA", "CA", "EA", "FA", "HA"}),
        "intangible"        => Line.new({"KD", "KF", "LV", "LW"}, {"PE", "PF", "PG", "PH"}, {"BB", "CB", "EB", "FB", "HB"}),
        "land"              => Line.new({"KG", "KI", "LX", "LY"}, {"PI", "PJ", "PK", "PL"}, {"BC", "CC", "EC", "FC", "HC"}),
        "building_own"      => Line.new({"KJ", "KL", "MA", "MB"}, {"PM", "PN", "PO", "PQ"}, {"BD", "CD", "ED", "FD", "HD"}),
        "building_other"    => Line.new({"KM", "KO", "MD", "ME"}, {"PR", "PS", "PT", "PU"}, {"BE", "CE", "EE", "FE", "HE"}),
        "building_fittings" => Line.new({"KP", "KR", "MG", "MH"}, {"PV", "PW", "PX", "PY"}, {"BF", "CF", "EF", "FF", "HF"}),
        "technical"         => Line.new({"KS", "KU", "MJ", "MK"}, {"PZ", "QA", "QB", "QC"}, {"BG", "CG", "EG", "FG", "HG"}),
        "general_fittings"  => Line.new({"KV", "KX", "MM", "MN"}, {"QD", "QE", "QF", "QG"}, {"BH", "CH", "EH", "FH", "HH"}),
        "transport"         => Line.new({"KY", "LA", "MP", "MQ"}, {"QH", "QI", "QJ", "QK"}, {"BJ", "CJ", "EJ", "FJ", "HJ"}),
        "office"            => Line.new({"LB", "LD", "MS", "MT"}, {"QL", "QM", "QN", "QO"}, {"BK", "CK", "EK", "FK", "HK"}),
        "other_tangible"    => Line.new({"LE", "LG", "MV", "MW"}, {"QP", "QR", "QS", "QT"}, {"BL", "CL", "EL", "FL", "HL"}),
        "in_progress"       => Line.new({"LH", "LJ", "MZ", "NA"}),
        "advances"          => Line.new({"LK", "LM", "ND", "NE"}),
        "participations"    => Line.new({"PD", "PF", "QV", "QW"}),
        "securities"        => Line.new({"PG", "PJ", "QZ", "RA"}),
        "loans"             => Line.new({"PK", "PM", "RD", "RE"}),
      },
      totals: [
        # Total I des incorporelles : 2055 seule (la 2054 n'en a pas).
        {Line.new({"", "", "", ""}, {"AE", "AF", "AG", "AH"}, {"AR", "AS", "AU", "AV", "AX"}), INTANGIBLE},
        # Total III des corporelles (2054) ; Total II des corporelles
        # amortissables (2055).
        {Line.new({"LN", "LP", "NG", "NH"}, {"QU", "QV", "QW", "QX"}, {"BM", "CM", "EM", "FM", "HM"}), TANGIBLE},
        {Line.new({"LQ", "LS", "NJ", "NK"}), FINANCIAL},
        {Line.new({"PN", "PQ", "RK", "RL"}, {"TA", "TB", "TC", "TD"}, {"BN", "CN", "EN", "FN", "HN"}),
         INTANGIBLE + TANGIBLE + FINANCIAL},
      ])

    # Tables par premier millésime d'application (rang `AAAA01`).
    TABLES = {202301 => TABLE_2023}

    # Millésime de la liasse d'un exercice clos le `ends_on` : année de
    # campagne, celle du lendemain de la clôture (règle de TELEDEC), au rang.
    def self.rank(ends_on : Time) : Int32
      (ends_on + 1.day).year * 100 + 1
    end

    # Table la plus récente applicable ; la plus ancienne avant la première.
    def self.table(rank : Int32) : Table
      TABLES[TABLES.keys.select(&.<=(rank)).max? || TABLES.keys.min]
    end

    # Cases 2054 et 2055 de l'état `view` (régime français) ; `nil` hors de
    # France ou si tout est nul.
    def self.boxes(view : Api::StatementView) : Hash(String, Hash(String, D))?
      return unless view.regime == "fr"
      table = table(rank(view.exercise.ends_on))
      values = view.rows.to_h { |row| {row.rubric, amounts(row)} }
      result = {"2054" => {} of String => D, "2055" => {} of String => D}
      table.rubrics.each do |rubric, line|
        values[rubric]?.try { |amounts| put(result, line, amounts) }
      end
      table.totals.each do |(line, rubrics)|
        put(result, line, sum(rubrics.compact_map { |rubric| values[rubric]? }))
      end
      result.reject! { |_, zones| zones.empty? }
      result.empty? ? nil : result
    end

    # Montants d'une rubrique arrondis à l'euro : brut (4), amortissements
    # (4), dérogatoires (5).
    private def self.amounts(row : Api::StatementRowView) : Array(D)
      derogatory_charge = row.derogatory_charge_duration + row.derogatory_charge_degressive
      derogatory_release = row.derogatory_release_duration + row.derogatory_release_degressive
      [row.gross_opening, row.gross_increase, row.gross_decrease, row.gross_closing,
       row.depreciation_opening, row.depreciation_charge, row.depreciation_decrease, row.depreciation_closing,
       row.derogatory_charge_duration, row.derogatory_charge_degressive, row.derogatory_release_duration,
       row.derogatory_release_degressive, derogatory_charge - derogatory_release].map { |value| euros(value) }
    end

    private def self.sum(list : Array(Array(D))) : Array(D)
      Array(D).new(13) { |index| list.sum(D.new(0), &.[index]) }
    end

    private def self.put(result : Hash(String, Hash(String, D)), line : Line, amounts : Array(D)) : Nil
      line.gross.each_with_index { |zone, index| set(result["2054"], zone, amounts[index]) }
      line.depreciation.try(&.each_with_index { |zone, index| set(result["2055"], zone, amounts[4 + index]) })
      line.derogatory.try(&.each_with_index { |zone, index| set(result["2055"], zone, amounts[8 + index]) })
    end

    private def self.set(zones : Hash(String, D), zone : String, amount : D) : Nil
      zones[zone] = amount unless zone.empty? || amount.zero?
    end

    private def self.euros(value : D) : D
      value.round(0, mode: :ties_away)
    end
  end
end
