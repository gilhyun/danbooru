class Note < ActiveRecord::Base
  attr_accessor :updater_id, :updater_ip_addr, :html_id
  belongs_to :post
  belongs_to :creator, :class_name => "User"
  belongs_to :updater, :class_name => "User"
  before_validation :initialize_creator, :on => :create
  before_validation :initialize_updater
  before_validation :blank_body
  validates_presence_of :post_id, :creator_id, :updater_id, :x, :y, :width, :height
  validate :post_must_exist
  validate :note_within_image, :message => "must be inside the image"
  has_many :versions, :class_name => "NoteVersion", :order => "note_versions.id ASC"
  after_save :update_post
  after_save :create_version
  validate :post_must_not_be_note_locked
  attr_accessible :x, :y, :width, :height, :body, :updater_id, :updater_ip_addr, :is_active, :post_id, :html_id

  module SearchMethods
    def active
      where("is_active = TRUE")
    end

    def body_matches(query)
      if query =~ /\*/ && CurrentUser.user.is_builder?
        where("body ILIKE ? ESCAPE E'\\\\'", query.to_escaped_for_sql_like)
      else
        where("body_index @@ plainto_tsquery(E?)", query.to_escaped_for_tsquery_split)
      end
    end

    def post_tags_match(query)
      joins(:post).where("posts.tag_index @@ to_tsquery('danbooru', E?)", query.to_escaped_for_tsquery_split)
    end

    def creator_name(name)
      where("creator_id = (select _.id from users _ where lower(_.name) = ?)", name.mb_chars.downcase)
    end

    def search(params)
      q = scoped
      return q if params.blank?

      if params[:body_matches].present?
        q = q.body_matches(params[:body_matches])
      end

      if params[:post_id].present?
        q = q.where("post_id = ?", params[:post_id].to_i)
      end

      if params[:post_tags_match].present?
        q = q.post_tags_match(params[:post_tags_match])
      end

      if params[:creator_name].present?
        q = q.creator_name(params[:creator_name].tr(" ", "_"))
      end

      if params[:creator_id].present?
        q = q.where("creator_id = ?", params[:creator_id].to_i)
      end

      q
    end
  end

  module ApiMethods
    def hidden_attributes
      super + [:body_index]
    end

    def serializable_hash(options = {})
      options ||= {}
      options[:except] ||= []
      options[:except] += hidden_attributes
      unless options[:builder]
        options[:methods] ||= []
        options[:methods] += [:creator_name]
      end
      hash = super(options)
      hash
    end

    def to_xml(options = {}, &block)
      options ||= {}
      options[:methods] ||= []
      options[:methods] += [:creator_name]
      super(options, &block)
    end
  end

  extend SearchMethods
  include ApiMethods

  def presenter
    @presenter ||= NotePresenter.new(self)
  end

  def initialize_creator
    self.creator_id = CurrentUser.id
  end

  def initialize_updater
    self.updater_id = CurrentUser.id
    self.updater_ip_addr = CurrentUser.ip_addr
  end

  def post_must_exist
    if !Post.exists?(post_id)
      errors.add :post, "must exist"
      return false
    end
  end

  def post_must_not_be_note_locked
    if is_locked?
      errors.add :post, "is note locked"
      return false
    end
  end

  def note_within_image
    return false unless post.present?
    if x < 0 || y < 0 || (x > post.image_width) || (y > post.image_height) || width < 0 || height < 0 || (x + width > post.image_width) || (y + height > post.image_height)
      self.errors.add(:note, "must be inside the image")
      return false
    end
  end

  def is_locked?
    Post.exists?(["id = ? AND is_note_locked = ?", post_id, true])
  end

  def blank_body
    self.body = "(empty)" if body.blank?
  end

  def creator_name
    User.id_to_name(creator_id).tr("_", " ")
  end

  def update_post
    if Note.exists?(["is_active = ? AND post_id = ?", true, post_id])
      execute_sql("UPDATE posts SET last_noted_at = ? WHERE id = ?", updated_at, post_id)
    else
      execute_sql("UPDATE posts SET last_noted_at = NULL WHERE id = ?", post_id)
    end
  end

  def create_version
    CurrentUser.user.increment!(:note_update_count)
    update_column(:version, version.to_i + 1)

    versions.create(
      :updater_id => updater_id,
      :updater_ip_addr => updater_ip_addr,
      :post_id => post_id,
      :x => x,
      :y => y,
      :width => width,
      :height => height,
      :is_active => is_active,
      :body => body,
      :version => version
    )
  end

  def revert_to(version)
    self.x = version.x
    self.y = version.y
    self.post_id = version.post_id
    self.body = version.body
    self.width = version.width
    self.height = version.height
    self.is_active = version.is_active
    self.updater_id = CurrentUser.id
    self.updater_ip_addr = CurrentUser.ip_addr
  end

  def revert_to!(version)
    revert_to(version)
    save!
  end

  def copy_to(new_post)
    new_note = dup
    new_note.post_id = new_post.id
    new_note.version = 0

    width_ratio = new_post.image_width.to_f / post.image_width
    height_ratio = new_post.image_height.to_f / post.image_height
    new_note.x = x * width_ratio
    new_note.y = y * height_ratio
    new_note.width = width * width_ratio
    new_note.height = height * height_ratio

    new_note.save
  end

  def self.undo_changes_by_user(user_id)
    transaction do
      notes = Note.joins(:versions).where(["note_versions.updater_id = ?", user_id]).select("DISTINCT notes.*").all
      NoteVersion.destroy_all(["updater_id = ?", user_id])
      notes.each do |note|
        first = note.versions.first
        if first
          note.revert_to!(first)
        end
      end
    end
  end
end
