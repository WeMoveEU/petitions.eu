# == Schema Information
#
# Table name: petitions
#
#  id                               :integer          not null, primary key
#  name                             :string(255)
#  subdomain                        :string(255)
#  description                      :text(65535)
#  initiators                       :text(65535)
#  statement                        :text(65535)
#  request                          :text(65535)
#  date_projected                   :date             default(NULL)
#  office_id                        :integer
#  organisation_id                  :integer
#  organisation_name                :string(255)
#  petitioner_organisation          :string(255)
#  petitioner_birth_date            :date
#  petitioner_birth_city            :string(255)
#  petitioner_name                  :string(255)
#  petitioner_address               :string(255)
#  petitioner_postalcode            :string(255)
#  petitioner_city                  :string(255)
#  petitioner_email                 :string(255)
#  petitioner_telephone             :string(255)
#  maps_query                       :string(255)
#  office_suggestion                :string(255)
#  organisation_kind                :string(255)
#  link1                            :string(255)
#  link2                            :string(255)
#  link3                            :string(255)
#  link1_text                       :string(255)
#  link2_text                       :string(255)
#  link3_text                       :string(255)
#  site1                            :string(255)
#  site1_text                       :string(255)
#  signatures_count                 :integer          default(0), not null
#  number_of_signatures_on_paper    :integer          default(0), not null
#  number_of_newsletters_sent       :integer          default(0), not null
#  created_at                       :datetime
#  updated_at                       :datetime
#  last_confirmed_at                :datetime
#  status                           :string(255)
#  manager_id                       :integer
#  show_twitter                     :boolean
#  show_history                     :boolean
#  show_map                         :boolean
#  twitter_query                    :string(255)
#  lat_lng                          :string(255)
#  lat_lng_sw                       :string(255)
#  lat_lng_ne                       :string(255)
#  special_count                    :integer          default(0), not null
#  display_more_information         :boolean
#  display_signature_person_citizen :boolean          default(FALSE)
#  display_signature_full_address   :boolean          default(FALSE)
#  archived                         :boolean          default(FALSE)
#  petition_type_id                 :integer
#  display_person_born_at           :boolean
#  display_person_birth_city        :boolean
#  locale_list                      :text(65535)
#  active_rate_value                :float(24)        default(0.0)
#  owner_id                         :integer
#  owner_type                       :string(255)
#  reference_field                  :string(255)
#  answer_due_date                  :date
#  slug                             :string(255)
#
Globalize.fallbacks = { en: [:en, :nl], nl: [:nl, :en] }

class Petition < ActiveRecord::Base
  extend ActionView::Helpers::TranslationHelper

  translates :name, :description, :initiators,
             :statement, :request, :slug,
             fallbacks_for_empty_translations: true,
             versioning: :paper_trail
  has_paper_trail only: [:name, :description, :initiators, :statement, :request]

  extend FriendlyId # must come after translates

  resourcify
  has_many :users, through: :roles

  serialize :locale_list, Array

  friendly_id :name, use: [:globalize, :finders]

  STATUS_LIST = [
    # we can view it but not sign?
    [t('petition.published'),         'published'],
    # we take the petition offline.
    [t('petition.withdrawn'),         'withdrawn'],
    # no confirmed author
    [t('petition.draft'),             'draft'],
    # still building author is confirmed
    [t('petition.concept'),           'concept'],
    # admin has to review the petition
    [t('petition.staging'),           'staging'],
    # admin reviewed the state
    [t('petition.live'),              'live'],
    # petitions we do not sign here
    [t('petition.not_signable_here'), 'not_signable_here'],
    # admin does not like this petition
    [t('petition.rejected'),          'rejected'],
    # petition should go to goverment
    [t('petition.to_process'),        'to_process'],
    # no owner?
    [t('petition.ghost'),             'ghost'],
    # petition is at goverment
    [t('petition.in_process'),        'in_process'],
    # petition is not at goverment
    [t('petition.not_processed'),     'not_processed'],
    # there is a goverment response
    # we are done!
    [t('petition.completed'),         'completed']
  ]

  # loketten
  LOKET_ADMIN = [
    [t('petition.withdrawn'),         'withdrawn'],
    [t('petition.to_process'),        'to_process']
  ]

  # petitionaris
  PETITIONARIS = [
    [t('petition.staging'), 'staging'], # awaiting moderation
  ]

  scope :live,      -> { where(status: 'live') }
  scope :live!,     -> { where('status != "live"') }
  scope :big,       -> { order(signatures_count: :desc) }
  scope :active,    -> { order(active_rate_value: :desc) }
  scope :newest,    -> { order(created_at: :desc) }

  belongs_to :owner, class_name: 'User'
  belongs_to :office
  belongs_to :petition_type
  belongs_to :organisation

  has_many :images, as: :imageable, dependent: :destroy
  accepts_nested_attributes_for :images

  # default_scope :order => 'petitions.name ASC'

  has_many :new_signatures

  has_many :signatures do
    def confirmed
      where(confirmed: true)
    end

    def special
      # where(confirmed: true, special: true).order('sort_order ASC, signed_at ASC')
      where(confirmed: true).order('sort_order DESC, signed_at ASC')
    end

    def recent
      where(confirmed: true).order('signed_at DESC')
    end

    def last_signed
      where(confirmed: true).order('signed_at DESC').limit(1).first
    end
  end

  has_many :updates
  has_many :task_statuses

  def get_count
    count = $redis.get("p#{id}-count").to_i
    if !count || count == 0
      signatures_count
    else
      count
    end
  end

  include StripWhitespace
  strip_whitespace :name, :description, :initiators, :statement, :request

  validates_presence_of :name
  validates_presence_of :description
  validates_presence_of :initiators
  validates_presence_of :statement
  validates_presence_of :request

  validates_format_of :subdomain, with: /\A[A-Za-z0-9-]+\z/, allow_blank: true
  validates_uniqueness_of :subdomain, case_sensitive: false, allow_blank: true
  validates_exclusion_of :subdomain, in: %w( www help api handboek petitie petities loket webmaster helpdesk info assets assets0 assets1 assets2 )

  after_update :send_status_mail

  def should_generate_new_friendly_id?
    slug.blank? || name_changed?
  end

  def send_status_mail
    if status_changed?

      users.each do |user|
        PetitionMailer.status_change_mail(self, target: user.email).deliver_later
      end

      PetitionMailer.status_change_mail(self, target: 'nederland@petities.nl').deliver_later
    end
  end

  def last_sig_update
    last = $redis.get("p-last-#{id}")
    if last
      last = Time.at(last.to_i)
      return last
    end
    1000.days.ago
  end

  def elapsed_time
    Time.now - (last_confirmed_at || Time.now)
  end

  def active_rate

    short = 1.0

    total = 100.0

    now = Time.now + 1.day

    15.times do
      key_d = "p-d-#{id}-#{now.year}-#{now.month}-#{now.day}"
      key_h = "p-h-#{id}-#{now.year}-#{now.month}-#{now.day}-#{now.hour}"
      vd = $redis.get(key_d) || 0
      vd = vd.to_f
      vh = $redis.get(key_h) || 0
      vh = vh.to_f
      short += vd
      short += vh
      now = now - 1.day
    end

    a_rate = short / total

    # remove old active rate
    $redis.zrem('active_rate', id)
    # add new active rate
    $redis.zadd('active_rate', a_rate, id)

    a_rate
  end

  def update_active_rate!
    active_rate
  end

  def is_hot?
    score = $redis.zscore('active_rate', id) || 0
    score > 0.4
  end

  ## petition status summary
  def state_summary
    return 'draft' if is_draft?
    return 'closed' if is_closed?
    return 'signable' if is_live?
    return 'in_treatment' if in_treatment?
    return 'is_answered' if is_answered?
  end

  ## edit a given petition
  def can_edit_petition?(user)
    return true if user.has_role? :admin

    office = Office.find(office_id)

    return true if office && user.has_role?(office, :admin)

    false
  end

  # All users who signed this petition should get an
  # answer
  def email_answer(answer = nil)
    ## fixme
  end

  def is_draft?
    %w(concept
       staging
       draft).include? status
  end

  def is_staging?
    %w(concept
       staging).include? status
  end

  def is_live?
    %w(live
       not_signable_here).include? status
  end

  def is_closed?
    %w(withdrawn
       rejected
       to_process
       not_processed).include? status
  end

  def in_treatment?
    %w(in_process
       to_process
       not_processed).include? status
  end

  def is_answered?
    'completed' == status
  end

  def get_answer
    updates.find_by(show_on_petition: true)
  end

  def display_city_select_box?
    if petition_type.present?
      petition_type.allowed_cities.present?
    elsif office.present? && office.petition_type.present?
      office.petition_type.allowed_cities.present?
    end
  end

  def redis_history_chart_json(hist = 10)
    start = Time.now - hist.day

    if created_at and start < created_at
      start = created_at
    end

    day_counts = []
    labels = []

    d = start

    hist.times do
      key = "p-d-#{id}-#{d.year}-#{d.month}-#{d.day}"
      c = $redis.get(key) || 0
      c = c.to_i
      day_counts.push(c)

      labels.push("#{d.year}-#{d.month}-#{d.day}")

      if d > Time.zone.now.beginning_of_day
        break
      end
      d = d + 1.day
    end

    if labels.size > 20
      factor = (labels.size / 20.0).ceil
      labels = labels.map.with_index { |l, i| i % factor == 0 ? l : '' }
    end

    [day_counts, labels]
  end

  def history_chart_json
    label_size = signatures.confirmed.limit(50).map(&:confirmed_at)
                 .compact
                 .group_by { |signature| signature.strftime('%Y-%m-%d') }
                 .map { |group| [group[0], group[1].size] } # .to_json.html_safe

    labels = label_size.map.with_index { |d_s, _i| d_s[0] }

    if labels.size > 20
      factor = (labels.size / 20.0).ceil
      labels = labels.map.with_index { |l, i| i % factor == 0 ? l : '' }
    end

    data = label_size.map { |d_s| d_s[1] }

    [data, labels]
  end

  def inc_signatures_count!
    self.signatures_count += 1
  end

  def links
    {
      links: [
        { link: link1, text: link1_text },
        { link: link2, text: link2_text },
        { link: link3, text: link3_text }
      ].select { |link| link[:link].present? },
      site: { link: site1, text: site1_text }
    }
  end

  def delete_keys

    r = $redis

    keys_d = r.keys("p-d-#{id}-*")
    keys_h = r.keys("p-h-#{id}-*")

    r.del(*keys_d) if keys_d.size > 0
    r.del(*keys_h) if keys_h.size > 0

  end

  def create_raw_sql_barchart_keys
     sql = "
     SELECT
     COUNT(id), petition_id,
     DATE_FORMAT(confirmed_at, '%Y/%m/%d') as theday
     FROM signatures
     WHERE petition_id=#{id}
     AND confirmed=true
     AND confirmed_at IS NOT NULL
     GROUP BY
     YEAR(confirmed_at), MONTH(confirmed_at), DAY(confirmed_at)
     ORDER BY theday;"

     day_counts_array = ActiveRecord::Base.connection.execute(sql)

     puts
     puts "ACTIVE DAYS: #{day_counts_array.count}"
     puts

     day_counts_array.each do |row|
      count = row[0]
      id = row[1]
      year, month, day = row[2].split('/')
      day_key = "p-d-#{id}-#{year}-#{month.to_i}-#{day.to_i}"
      $redis.set(day_key, count)
     end

  end

  def create_hour_keys
    hour24ago = Time.zone.now.beginning_of_day - 1.day
    # create year/day/hour scores!
    recent_signatures = self.signatures
                            .confirmed
                            .order("confirmed_at DESC")
                            .where("confirmed_at >= ?", hour24ago)

    if recent_signatures.count == 0
      return
    end

    puts
    puts "SIGS TODAY: #{recent_signatures.count}"
    puts

    recent_signatures.each do |signature|
      signature.set_redis_keys(true)
    end

  end


end
