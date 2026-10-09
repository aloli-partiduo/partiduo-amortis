# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Coefficients de l'amortissement dégressif fiscal français (CGI,
  # art. 39 A ; D-AMO-006), datés : le coefficient applicable est celui en
  # vigueur à la date d'acquisition du bien, selon sa durée normale
  # d'utilisation (3 ou 4 ans, 5 ou 6 ans, plus de 6 ans). En deçà de trois
  # ans, le dégressif n'est pas admis. Interne.
  module Coefficients
    # Période de validité (début compris, fin exclue) et coefficients pour
    # 3-4 ans, 5-6 ans, plus de 6 ans.
    record Period, from : Time, before : Time?, short : BigDecimal, medium : BigDecimal, long : BigDecimal, source : String

    FR = [
      Period.new(Time.utc(1960, 1, 1), Time.utc(2001, 1, 1), BigDecimal.new("1.5"), BigDecimal.new("2"),
        BigDecimal.new("2.5"), "cgi_39a_1960"),
      Period.new(Time.utc(2001, 1, 1), Time.utc(2008, 12, 4), BigDecimal.new("1.25"), BigDecimal.new("1.75"),
        BigDecimal.new("2.25"), "lf_2001"),
      Period.new(Time.utc(2008, 12, 4), Time.utc(2010, 1, 1), BigDecimal.new("1.75"), BigDecimal.new("2.25"),
        BigDecimal.new("2.75"), "lfr_2008"),
      Period.new(Time.utc(2010, 1, 1), nil, BigDecimal.new("1.25"), BigDecimal.new("1.75"), BigDecimal.new("2.25"),
        "lf_2001"),
    ]

    # Durée minimale du dégressif, en mois (trois ans).
    MIN_MONTHS = 36

    # Coefficient français d'un bien acquis le `acquired_on`, d'une durée de
    # `months` mois ; `nil` si le dégressif n'est pas admis.
    def self.fr(acquired_on : Time, months : Int32) : BigDecimal?
      return if months < MIN_MONTHS
      period = FR.find { |item| item.from <= acquired_on && (item.before.nil? || acquired_on < item.before.as(Time)) }
      return if period.nil?
      if months <= 48
        period.short
      elsif months <= 72
        period.medium
      else
        period.long
      end
    end

    # Taux dégressif belge : le double du taux linéaire, au plus 40 %
    # (CIR 92, art. 64).
    BE_CAP = BigDecimal.new("0.4")

    def self.be_rate(months : Int32) : BigDecimal
      rate = BigDecimal.new(24) / months
      rate > BE_CAP ? BE_CAP : rate
    end

    # Dégressif belge supprimé pour les sociétés à partir des biens acquis
    # ou constitués le 1er janvier 2020 (loi du 25 décembre 2017).
    BE_ABOLISHED_ON = Time.utc(2020, 1, 1)
  end
end
