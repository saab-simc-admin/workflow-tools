#!/usr/bin/env ruby
##############################################################################
#
# enforce-workflow
# -------------------------
# A server-side pre-receive git hook for checking the GPG signature
# and other small workflow things of a pushed commit.
#
# Allowed signers
# ---------------
# Move collaborators.yaml to the .git/ directory of your repository
# and write your usernames and GnuPG key fingerprints in it. The
# format is a YAML hash from usernames to 40-character hexadecimal
# fingerprint strings without spaces.
#
# Config
# ------
# hooks.allowunsignedcommits
#   This boolean sets whether unsigned commits are allowed. By
#   default, they are not allowed.
# hooks.allowunsignedtags
#   This boolean sets whether unsigned tags are allowed. By default,
#   they are not allowed.
# hooks.allowcommitsonmaster
#   This boolean sets whether non-merge commits are allowed on master. By
#   default, these are not allowed.
# hooks.allowunannotated
#   This boolean sets whether unannotated tags will be allowed into the
#   repository.  By default they won't be.
# hooks.allowdeletetag
#   This boolean sets whether deleting tags will be allowed in the
#   repository.  By default they won't be.
# hooks.allowmodifytag
#   This boolean sets whether a tag may be modified after creation. By default
#   it won't be.
# hooks.allowdeletebranch
#   This boolean sets whether deleting branches will be allowed in the
#   repository.  By default they won't be.
# hooks.denycreatebranch
#   This boolean sets whether remotely creating branches will be denied
#   in the repository.  By default this is allowed.
##############################################################################

require 'rugged'
require 'gpgme'
require 'yaml'

class WorkflowEnforcer
  def initialize
    @repo = Rugged::Repository.new('.')
    @crypto = GPGME::Crypto.new

    @collaborators = YAML.load_file(@repo.path + 'collaborators.yaml')
  end

  def find_signer(keyid)
    keys = GPGME::Key.find(:public, keyid)

    if keys.length.zero?
      puts "*** Key #{keyid} not in allowed list."
      return false
    end

    if keys.length > 1
      puts "*** Multiple keys matched short ID #{keyid}."
      return false
    end

    @collaborators.key(keys[0].fingerprint)
  end

  # Check if the repository configuration accepts deleting the reference
  # +ref+.
  def accept_deletion?(ref)
    result = false
    if ref =~ %r{^refs\/heads\/} && (@repo.config['hooks.allowdeletebranch'] != 'true')
      puts '*** Deleting a branch is not allowed in this repository.'
    elsif ref =~ %r{^refs\/remotes\/} && (@repo.config['hooks.allowdeletebranch'] != 'true')
      puts '*** Deleting a remote tracking branch is not allowed in this repository.'
    elsif ref =~ %r{^refs\/tags\/} && (@repo.config['hooks.allowdeletetag'] != 'true')
      puts '*** Deleting a tag is not allowed in this repository.'
    else
      puts "*** Accepting deletion of ref #{ref}."
      result = true
    end
    return result
  end

  # Check if the repository configuration accepts updating master from
  # +old+ to +new+.
  def accept_update_of_master?(old, new)
    result = false
    if @repo.config['hooks.allowcommitsonmaster'] == 'true'
      result = true
    else
      # The only commits allowed on master are merges which have rev_old
      # as a direct parent of rev_new, or the initial commit creating
      # master.
      if old.to_i(16).zero?
        # Initial creation of master. Let this update through.
        puts '*** Accepting creation of master branch.'
        result = true
      else
        # We only want merges on master. A merge is a commit with at
        # least two parents, and one of them has to be the old target.
        parents = @repo.lookup(new).parent_ids
        if parents.length >= 2 &&
                                parents.include?(old)
          result = true
        else
          puts '*** Master only accepts merges of feature branches.'
        end
      end
    end
    return result
  end

  # Check if this repository accepts the signature on the object +oid+,
  # whose +type+ is either +:commit+, +:merge+, or +:tag+. For a tag,
  # +ref+ is the tag name.
  def accept_signature?(oid, type: '', ref: '')
    case type
    when :commit
      return true if @repo.config['hooks.allowunsignedcommits'] == 'true'
      extract_signature = Rugged::Commit.method(:extract_signature)
      id = oid
    when :merge
      return true if @repo.config['hooks.allowunsignedcommits'] == 'true'
      extract_signature = Rugged::Commit.method(:extract_signature)
      id = oid
    when :tag
      return true if @repo.config['hooks.allowunsignedtags'] == 'true'
      extract_signature = Rugged::Tag.method(:extract_signature)
      id = ref
    else
      puts "*** Don't know how to check the signature of the #{type} with oid #{oid}."
      return false
    end

    signed = false
    fingerprint = nil
    signer = nil

    signature, plaintext = extract_signature.call(@repo, oid)
    if signature && plaintext
      @crypto.verify(signature, signed_text: plaintext) do |sig|
        signed = sig.valid?
        if signed
          fingerprint = sig.fingerprint
          signer = find_signer(fingerprint)
        end
      end
    end

    if !signed
      puts "*** Bad signature on #{type} #{id}."
      return false
    elsif signer
      puts "*** Good signature on #{type} #{id} by #{signer} (#{fingerprint})."
      return true
    else
      # Signed, but not allowed
      puts "*** #{type.capitalize} #{id} signed by unauthorised key #{fingerprint}."
      return false
    end
  end

  # Walk the commit graph between +old+ and +new+, checking signatures
  # on each commit object encountered.
  #
  # Returns [bool, int]. The boolean is true if all commits are properly
  # signed, false otherwise. If the boolean is true, the integer says
  # how many objects were encountered in the graph. If the boolean is
  # false, the value of the integer is undefined.
  def walk_graph(old, new, ref)
    walker = Rugged::Walker.new(@repo)

    # Get all new commits on branch ref, even if it's a new branch.
    walker.push(new)

    # old is nothing, so this is the creation of a new ref.
    if old.to_i(16).zero?
      # List everything reachable from new but not any old heads.
      # However, when this is run locally as a pre-push hook, ref has
      # already been updated, so hiding that would exclude the entire
      # graph.
      @repo.references.
                      each('refs/heads/*').
                                          reject { |r| r.name == ref }.
                                                                      map { |ref| walker.hide(ref.target.oid) }
    else
      # old was already in the tree, so it must by definition be OK.
      walker.hide(old)
    end

    commit_count = 0
    update_allowed = true
    walker.each do |commit|
      # walker.count would have consumed the walker, so instead track
      # the number of commits manually.
      commit_count += 1

      if commit.oid.to_i(16).zero?
        puts "*** Deletion of ref #{ref} in the middle of the commit graph? This can't happen; rejecting."
        update_allowed = false
      elsif commit.parent_ids.length >= 2
        commit_type = :merge
      else
        commit_type = commit.type
      end

      if commit_type == :commit &&
      old.to_i(16).zero? &&
                          @repo.config['hooks.denycreatebranch'] == 'true'
        puts '*** Creating a branch is not allowed in this repository.'
        update_allowed = false
        break
      end

      if !accept_signature?(commit.oid, type: commit_type)
        update_allowed = false
        break
      end

      if commit_type != :commit && commit_type != :merge
        puts "*** Unknown type of update to ref #{ref} of type #{commit_type}."
        update_allowed = false
        break
      end
    end

    return [update_allowed, commit_count]
  end

  # Check if the lightweight tag +ref+ should be allowed to be created.
  def allow_lightweight_tag?(ref)
    if (@repo.config['hooks.allowunsignedtags'] != 'true') ||
       (@repo.config['hooks.allowunannotated'] != 'true')
      puts "*** The un-annotated tag #{ref} is not allowed in this repository."
      puts "*** Use 'git tag [ -a | -s ]' for tags you want to propagate."
      return false
    end
    return true
  end

  # Check if the annotated tag +ref+, currently pointing to commit ID
  # +old+ (or 0 if a new reference), should be allowed to be created or
  # updated to point to commit ID +new+.
  def allow_annotated_tag?(old, new, ref)
    if old.to_i(16).nonzero? && (@repo.config['hooks.allowmodifytag'] != 'true')
      puts "*** Tag #{ref} already exists."
      puts '*** Modifying a tag is not allowed in this repository.'
      return false
    else
      return accept_signature?(new, type: :tag, ref: ref)
    end
  end

  # Check if the update of +ref+ from +rev_old+ to +rev_new+ should be
  # allowed. Returns if it should be accepted, exits the program with
  # status 1 if it should be rejected.
  def enforce_workflow(rev_old, rev_new, ref)
    # A hash full of zeroes is how Git represents "nothing".
    if rev_new.to_i(16).zero?
      # Deletion of a ref. This needs to be handled separately, since
      # the walker can't handle a start ID of 0x0.
      exit 1 unless accept_deletion?(ref)
      return
    end

    # Normally, the only commits allowed on master are merges which have
    # rev_old as a direct parent of rev_new.
    #
    # We have to check this in a separate step, since we won't have
    # enough context while walking through the commit list to do this
    # check properly.
    if ref == 'refs/heads/master'
      exit 1 unless accept_update_of_master?(rev_old, rev_new)
    end

    # Check commit signatures.
    update_allowed, commit_count = walk_graph(rev_old, rev_new, ref)
    exit 1 unless update_allowed

    if commit_count.zero?
      # rev_new pointed to something considered by the walker to already
      # be in the commit graph, which could be a commit (if we're adding
      # a lightweight tag) or a tag object (if we're adding an annotated
      # tag), since the walker doesn't consider the tag object to be
      # separate from the commit it points to.
      commit = @repo.lookup(rev_new)
      case commit.type
      when :commit
        # The ref points to a commit, i.e. the ref is a lightweight tag.
        exit 1 unless allow_lightweight_tag?(ref)
      when :tag
        # The ref is an annotated tag
        exit 1 unless allow_annotated_tag?(rev_old, rev_new, ref)
      else
        puts "*** No new commits, but the pushed ref #{ref} is a \"#{commit.type}\" instead of a tag? I'm confused."
        exit 1
      end
    end
  end
end
