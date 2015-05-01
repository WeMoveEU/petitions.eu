class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  
  protect_from_forgery with: :exception
  if Rails.env.test?
    protect_from_forgery with: :null_session
  else 
    protect_from_forgery with: :exception
  end

  include Pundit


  before_filter :set_locale

  private
    def set_locale
      #TODO check params locale option?
      I18n.locale = http_accept_language.compatible_language_from(I18n.available_locales)
    end

end
