namespace :petition do

  desc 'Send warning of expiring due date'
  task :send_warning_due_date => :environment do

    Rails.logger = ActiveSupport::Logger.new('log/send_petition_due_date_warning.log')

    almost_petitions = Petition.
      where('date_projected < ?', 7.days.from_now).
      where('date_projected > ?', 6.days.from_now).
      where(status: :live).limit(100)

    Rails.logger.debug('due date warnings %s' % almost_petitions.size)

    almost_petitions.each do |petition|
      if almost_petitions.signatures.confirmed.size < 10
        m = PetitionMailer.warning_due_date_mail(petition)
        m.deliver_later
      end
    end
  end

  desc 'handle over due petitions'
  task :handle_overdue_petitions => :environment do
    Rails.logger = ActiveSupport::Logger.new('log/clear_failed_petition.log')
    overdue_petitions = Petition.
      where('date_projected < ?', Time.now).
      where(status: :live).limit(100)

    overdue_petitions.each do |petition|
      if petition.signatures.confirmed.size < 10
        Rails.logger.debug('withdrawn %s %s' % [petition.id, petition.name])
        petition.status == 'withdrawn'
        petition.save
      elsif petition.updates.size < 1
        # change status to orphan
        petition.status == 'orphan'
        Rails.logger.debug('orphan %s %s' % [petition.id, petition.name])

      else
        Rails.logger.debug('request answer %s %s' % [petition.id, petition.name])
        # send request to answer to office
        # change status to to_process
        #
      end
    end
  end

  desc 'Get reference number'
  task :get_reference_number => :environment do
    Rails.logger = ActiveSupport::Logger.new('log/get_reference_number.log')

    missing_reference_number = Petition.
      where('date_projected < ?', Time.now).
      where(reference_field: nil).
      where(status: :to_process).limit(110)

    Rails.logger.debug(missing_reference_number.size)

    missing_reference_number.each do |petition|

      # find task or create
      task_status = TaskStatus.find_or_create_by(
        task_name: 'get_reference_number',
        petition_id: petition.id)

      if task_status.count.nil?
        task_status.count = 0
      end

      if task_status.last_action.nil?
        task_status.last_action = Time.now
        m = PetitionMailer.reference_number_mail(petition)
        # m.deliver_later
        Rails.logger.debug('sending first mail.')
        task_status.count += 1
      elsif
        if task_status.count < 3
          if task_status.last_action < 7.days.ago
            task_status.last_action = Time.now
            m = PetitionMailer.reference_number_mail(petition)
            #m.deliver_later
            Rails.logger.debug('sending %s mail..' % task_status.count)
          end
        end
      end
      # save the current task status
      task_status.save
    end
  end

  desc 'Get answer for petition from office'
  task 'get_answer_from_office' => :environment do
    Rails.logger = ActiveSupport::Logger.new('log/get_answer.log')

    # find all petitions that not have an answer yet
    need_answers = Petition.where(status: 'in_process').
      where('date_projected < ?', Time.now).
      joins(:updates).
      where(newsitems: {show_on_petition: [nil, false]}).limit(100)

    Rails.logger.debug(need_answers.size)

    need_answers.each do |petition|
       task_status = TaskStatus.find_or_create_by(
        task_name: 'get_answer',
        petition_id: petition.id)

       if task_status.count.nil? 
         task_status.count = 0
         task_status.last_action = Time.now
       end

       if task_status.count == 0 or (task_status.last_action < 7.days.ago && task_status.count < 3)
         # send office reminder
         task_status.count += 1
         task_status.last_action = Time.now
         mail = PetitionMailer.office_ask_for_answer_mail(petition)
         #mail.deliver_later
         Rails.logger.debug(
           'asked %s x %s for answer on %s' % [
             petition.office.name, 
             task_status.count,
             petition.name])

         task_status.save
       end
    end
  end

  desc 'publish answer to interested people'
  task 'publish_answer_to_subscribers' => :environment do
    Rails.logger = ActiveSupport::Logger.new('log/publish_answer.log')

    # find all petitions with an answer and are not completed
    have_answer = Petition.where(status: 'in_process').
      where('date_projected < ?', Time.now).
      joins(:updates).
      where(newsitems: {show_on_petition: true}).limit(10)

    # find users that want to know about the answer
    have_answer.each do |petition|
    
      publish_task = TaskStatus.find_or_create_by(
        task_name: 'publish_answer',
        petition_id: petition.id)

       if publish_task.count.nil? 
         publish_task.count = 0
         publish_task.last_action = Time.now
       else
         # skip
         Rails.logger.debug('we only publish once %s' % petition.name) 
         next
       end

      # find all people that want to be informed
      inform_me = Pledge.
        where(petition_id: petition.id).
        where(inform_me: true)

      message = '%s people want answer on %s'% [inform_me.size, petition.name]
      Rails.logger.debug(message) 
      publish_task.message = message

      # find the answer
      answer = petition.updates.where(show_on_petition: true).first

      # inform each pledged user of answer
      inform_me.each do |pledge|
        m = SignatureMailer.inform_user_of_answer_mail(
          pledge.signature, pledge.petition, answer
        )
        # deliver the answer
        m.deliver_later
      end

      # set petition status on completed
      petition.status = 'completed'
      Rails.logger.debug('completed publish %s ' % petition.name) 
      petition.save
      publish_task.save
    end
  end
end