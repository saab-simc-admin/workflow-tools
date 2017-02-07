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

repo = Rugged::Repository.new('.')
crypto = GPGME::Crypto.new

@collaborators = YAML.load_file(repo.path + 'collaborators.yaml')

def is_allowed_signer(keyid)
  keys = GPGME::Key.find(:public, keyid)

  if keys.length == 0
    puts "*** Key #{keyid} not in allowed list."
    return false
  end

  if keys.length > 1
    puts "*** Multiple keys matched short ID #{keyid}."
    return false
  end

  return !!@collaborators.key(keys[0].fingerprint)
end

# Calling convention, from githooks(5):
#
# This hook executes once for the receive operation. It takes no
# arguments, but for each ref to be updated it receives on standard
# input a line of the format:
#
#     <old-value> SP <new-value> SP <ref-name> LF
#
# where <old-value> is the old object name stored in the ref,
# <new-value> is the new object name to be stored in the ref and
# <ref-name> is the full name of the ref. When creating a new ref,
# <old-value> is 40 0.

STDIN.each do |line|
  rev_old, rev_new, ref = line.split

  # A hash full of zeroes is how Git represents "nothing".
  if rev_new.to_i(16) == 0
    # Deletion of a ref. This needs to be handled separately, since
    # the walker can't handle a start ID of 0x0.
    if ref =~ /^refs\/heads\// and not repo.config['hooks.allowdeletebranch'] == 'true'
      puts "*** Deleting a branch is not allowed in this repository."
      exit 1
    elsif ref =~ /^refs\/remotes\// and not repo.config['hooks.allowdeletebranch'] == 'true'
      puts "*** Deleting a remote tracking branch is not allowed in this repository."
      exit 1
    elsif ref =~ /^refs\/tags\// and not repo.config['hooks.allowdeletetag'] == 'true'
      puts "*** Deleting a tag is not allowed in this repository."
      exit 1
    end
    puts "*** Accepting deletion of ref #{ref}."
    next
  end

  if not repo.config['hooks.allowcommitsonmaster'] == 'true'
    ## The only commits allowed on master are merges which have
    ## rev_old as a direct parent of rev_new.
    ##
    ## We have to check this in a separate step, since we won't have
    ## enough context while walking through the commit list to do this
    ## check properly.
    if ref == "refs/heads/master"
      # We only want merges on master. A merge is a commit with at
      # least two parents, and one of them has to be the old target.
      parents = repo.lookup(rev_new).parent_ids
      if parents.length < 2 or
          not parents.include?(rev_old)
        puts "*** Master only accepts merges of feature branches."
        exit 1
      end
    end
  end

  walker = Rugged::Walker.new(repo)

  # Get all new commits on branch ref, even if it's a new branch.
  walker.push(rev_new)

  # rev_old is nothing, so this is the creation of a new ref.
  if rev_old.to_i(16) == 0
    # List everything reachable from rev_new but not any heads.
    repo.references.each {|ref| walker.hide(ref.target.oid)}
  else
    # rev_old was already in the tree, so it must by definition be OK.
    walker.hide(rev_old)
  end

  commit_count = 0
  walker.each do |commit|
    # walker.count would have consumed the walker, so instead track
    # the number of commits manually.
    commit_count += 1

    if commit.oid.to_i(16) == 0
      puts "*** Deletion of ref #{ref} in the middle of the commit graph? This can't happen; rejecting."
      exit 1
    elsif commit.parent_ids.length >= 2
      commit_type = :merge
    else
      commit_type = commit.type
    end

    allowed = false
    signed = false
    signer = ''
    signature, plaintext = Rugged::Commit.extract_signature(repo, commit.oid)
    crypto.verify(signature, :signed_text => plaintext) do |signature|
      signed = signature.valid?
      next if not signed
      signer = signature.fingerprint
      allowed = is_allowed_signer(signer)
    end

    case commit_type
    when :commit
      if rev_old.to_i(16) == 0 and repo.config['hooks.denycreatebranch'] == 'true'
        puts "*** Creating a branch is not allowed in this repository."
        exit 1
      end

      if not repo.config['hooks.allowunsignedcommits'] == 'true'
        if not signed
          puts "*** Bad signature on commit #{commit.oid}."
          exit 1
        elsif allowed
          puts "*** Good signature on commit #{commit.oid} by #{signer}."
        else
          # Signed, but not allowed
          puts "*** Commit #{commit.oid} signed by unauthrosed signer #{signer}."
          exit 1
        end
      end

    when :merge
      if not repo.config['hooks.allowunsignedcommits'] == 'true'
        if not signed
          puts "*** Bad signature on merge #{commit.oid}."
          exit 1
        elsif allowed
          puts "*** Good signature on merge #{commit.oid} by #{signer}."
        else
          # Signed, but not allowed
          puts "*** Merge #{commit.oid} signed by unauthorised signer #{signer}."
          exit 1
        end
      end

    else
      puts "*** Unknown type of update to ref #{ref} of type #{commit_type}."
    end

    if commit_count == 0
      # rev_new pointed to something considered by the walker to already
      # be in the commit graph, which could be a commit (if we're adding
      # a lightweight tag) or a tag object (if we're adding an annotated
      # tag), since the walker doesn't consider the tag object to be
      # separate from the commit it points to.
      commit = repo.lookup(rev_new)
      case commit.type
      when :commit
        # The ref points to a commit, i.e. the ref is a lightweight tag.
        if not repo.config['hooks.allowunsignedtags'] == 'true' or
            not repo.config['hooks.allowunannotated'] == 'true'
          puts "*** The un-annotated tag #{ref} is not allowed in this repository."
          puts "*** Use 'git tag [ -a | -s ]' for tags you want to propagate."
          exit 1
        end
      when :tag
        # The ref is an annotated tag
        if rev_old.to_i(16) == 0 and not repo.config['hooks.allowmodifytag'] == 'true'
          puts "*** Tag #{ref} already exists."
          puts "*** Modifying a tag is not allowed in this repository."
        else
          if not repo.config['hooks.allowunsignedtags'] == 'true'
            if allowed
              puts "*** Good signature on tag #{ref} by #{signer}."
            else
              puts "*** Rejecting tag #{ref} due to lack of a valid GPG signature."
              exit 1
            end
          end
        end
      else
        puts "*** No new commits, but the pushed ref #{ref} is a \"#{commit.type}\" instead of a tag? I'm confused."
        exit 1
      end
    end
  end
end
