class Admin::UserCreationsController < ApplicationController
  
  before_action :admin_only
  before_action :get_creation
  before_action :can_be_marked_as_spam, only: [:set_spam]

  def get_creation
    raise "Redshirt: Attempted to constantize invalid class initialize #{params[:creation_type]}" unless %w(ExternalWork Bookmark Work).include?(params[:creation_type])
    @creation_class = params[:creation_type].constantize
    @creation = @creation_class.find(params[:id])
  end
  
  def can_be_marked_as_spam
    unless @creation_class && @creation_class == Work
      flash[:error] = ts("You can only mark works as spam currently.")
      redirect_to @creation and return
    end
  end
  
  # Removes an object from public view
  def hide
    @creation.hidden_by_admin = (params[:hidden] == "true")
    @creation.save(validate: false)
    action = @creation.hidden_by_admin? ? "hide" : "unhide"
    AdminActivity.log_action(current_admin, @creation, action: action)
    flash[:notice] = @creation.hidden_by_admin? ?
                        ts("Item has been hidden.") :
                        ts("Item is no longer hidden.")
    if @creation_class == Comment
      redirect_to(@creation.ultimate_parent) 
    elsif @creation_class == ExternalWork || @creation_class == Bookmark
      redirect_to(request.env["HTTP_REFERER"] || root_path)
    else
      unless action == "unhide" || @creation_class == Work
        # Email users so they're aware of Abuse action
        # Emails for works are handled in the work class
        orphan_account = User.orphan_account
        users = @creation.pseuds.map(&:user).uniq
        users.each do |user|
          unless user == orphan_account
            UserMailer.admin_hidden_work_notification(@creation.id, user.id).deliver
          end
        end
      end
      redirect_to(@creation)
    end
  end  
  
  def set_spam
    action = "mark as " + (params[:spam] == "true" ? "spam" : "not spam")
    AdminActivity.log_action(current_admin, @creation, action: action, summary: @creation.inspect)    
    if params[:spam] == "true"
      @creation.mark_as_spam!
      @creation.update_attribute(:hidden_by_admin, true)
      flash[:notice] = ts("Work was marked as spam and hidden.")
    else
      @creation.mark_as_ham!
      @creation.update_attribute(:hidden_by_admin, false)
      flash[:notice] = ts("Work was marked not spam and unhidden.")
    end
    redirect_to(@creation)
  end

  def destroy
    AdminActivity.log_action(current_admin, @creation, action: "destroy", summary: @creation.inspect)
    @creation.destroy
    flash[:notice] = ts("Item was successfully deleted.")
    if @creation_class == Comment 
      redirect_to(@creation.ultimate_parent) 
    elsif @creation_class == ExternalWork
      redirect_to bookmarks_path
    else
     redirect_to works_path
    end
  end
end
