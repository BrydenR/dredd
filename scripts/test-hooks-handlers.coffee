# Spawns dependent integration builds of hook handlers with current Dredd,
# where 'current Dredd' means whatever is currently in its repository under
# the last commit on currently active branch.
#
# Purpose:
#   Thanks to this we can be sure we did not break hook handler implementations
#   with a new version of Dredd or with a major refactoring.
#
# Usage:
#   The script is automatically ran by Travis CI in one of the builds in
#   the build matrix every time the tested commit is tagged:
#
#       $ npm version
#       $ git push origin ... --tags
#
#   When testing commits without tag, you can magically trigger these
#   integration tests by writing 'tests hook handlers' into the commit message:
#
#       $ git commit -m 'Fixes everything, closes #123, tests hook handlers.'
#       $ git push origin ...
#
# How it works:
#   1. Every time commit is pushed to GitHub, Travis CI automatically starts
#      a new build.
#   2. The build is defined by contents of `.travis.yml`. It runs regular tests
#      and then runs this script, `npm run test:hook-handlers`.
#   3. This script...
#       1. makes sure it is ran for just one build job within the build matrix.
#       2. checks whether hook handler integration tests were triggered or not.
#          **If the tested commit is part of PR or its commit message contains
#          words "tests hook handlers", it continues.** Otherwise it skips
#          the tests (ends immediately with 0 exit status code).
#       3. creates special dependent integration branches for each hook handler
#          implementation. In these branches, it takes whatever is in master
#          branch of the hook handler repository with the only difference that
#          instead of `npm i -g dredd` it links the Dredd from currently tested
#          commit.
#       4. pushes these dependent branches to GitHub, which triggers dependent
#          Travis CI builds. If dependent build would run in a build matrix,
#          selects language version with the highest number.
#       5. if the tests were triggered by PR, every dependent build informs
#          the PR about the result and if it passed, it deletes its branch
#
# Known issues:
#   * If `master` branch of hook handler repository becomes red, this whole
#     build will fail and we won't be able to release new version of Dredd
#     (not with green status). Instead, we should integrate with commit
#     corresponding to the latest release of the hook handler implementation.
#   * If the main Travis CI build where the script is being ran gets canceled,
#     the script won't cleanup the dependent branches on GitHub.

fs = require('fs')
execSync = require('sync-exec')
{exec} = require('child_process')
async = require('async')
yaml = require('js-yaml')
request = require('request')


unless process.env.CI
  console.error('''\
    This script is meant to be ran on Travis CI. It is not optimized (yet) for
    local usage. It could mess up your Git repository.
  ''')
  process.exit(1)


################################################################################
##                                  SETTINGS                                  ##
################################################################################

JOBS = [
  #   name: 'ruby-hooks-handler'
  #   repo: 'https://github.com/apiaryio/dredd-hooks-ruby.git'
  #   matrix: 'rvm'
  # ,
    name: 'python-hooks-handler'
    repo: 'https://github.com/apiaryio/dredd-hooks-python.git'
    matrix: 'python'
  # ,
  #   name: 'php-hooks-handler'
  #   repo: 'https://github.com/ddelnano/dredd-hooks-php.git'
  #   matrix: 'php'
  # ,
  #   name: 'perl-hooks-handler'
  #   repo: 'https://github.com/ungrim97/Dredd-Hooks.git'
  #   matrix: 'perl'
  # ,
  #   name: 'go-hooks-handler'
  #   repo: 'https://github.com/snikch/goodman.git'
  #   matrix: 'go'
]

TRAVIS_CONFIG_FILE = '.travis.yml'
TRIGGER_KEYWORD = 'tests hook handlers' # inspired by https://help.github.com/articles/closing-issues-via-commit-messages/
LINKED_DREDD_DIR = './__dredd__'
RE_DREDD_INSTALL_CMD = /npm ([ \-=\w]+ )?i(nstall)? ([ \-=\w]+ )?dredd/
DREDD_LINK_CMD = "npm link --python=python2 #{LINKED_DREDD_DIR}"


################################################################################
##                                   HELPERS                                  ##
################################################################################

# Redirects both stderr and strout to /dev/null. Should be added to all commands
# dealing with GitHub token so the token won't be disclosed in build output
# in case of errors.
DROP_OUTPUT = '> /dev/null 2>&1'


# Returns trimmed stdout for given execSync result.
getTrimmedStdout = (execSyncResult) ->
  execSyncResult?.stdout?.trim?() or ''


# Moves contents of the root directory to given directory. Ignores given
# excluded paths.
moveAllFilesTo = (directory, excludedPaths = []) ->
  console.log('moveAllFilesTo', directory, excludedPaths)
  excludedPaths.push(directory)

  # Make sure directory exists and is empty.
  execSync('rm -rf ' + directory)
  execSync('mkdir ' + directory)

  excludes = buildFindExcludes(excludedPaths)
  console.log("find . #{excludes} -exec mv -t '#{directory}' '{}' +")
  execSync("find . #{excludes} -exec mv -t '#{directory}' '{}' + #{DROP_OUTPUT}")


# Takes ['./a', './b'] and produces "-not -path './a' -and -not -path './b'"
buildFindExcludes = (excludedPaths) ->
  expressions = excludedPaths.map((path) -> "-not -path '#{path}'")
  return expressions.join(' -and ')


# Replaces given pattern with replacement in given file. Returns boolean whether
# any changes were made.
replaceDreddInstallation = ->
  contents = fs.readFileSync(TRAVIS_CONFIG_FILE, 'utf-8')
  unless contents.match(RE_DREDD_INSTALL_CMD)
    return false
  contents = contents.replace(RE_DREDD_INSTALL_CMD, DREDD_LINK_CMD)
  fs.writeFileSync(TRAVIS_CONFIG_FILE, contents, 'utf-8')
  return true


# Exits the script in case Travis CI CLI isn't installed.
requireTravisCli = ->
  unless getTrimmedStdout(execSync('which travis'))
    console.error('The travis command could not be found. Run \'gem install travis\'.')
    process.exit(1)


# If Git author is empty, sets the commiter of the last commit as an author.
ensureGitAuthor = (testedCommit) ->
  name = getTrimmedStdout(execSync('git show --format="%cN" -s ' + testedCommit))
  console.log("Setting Git user name to '#{name}'.")
  execSync("git config user.name '#{name}'")

  email = getTrimmedStdout(execSync('git show --format="%cE" -s ' + testedCommit))
  console.log("Setting Git e-mail to '#{email}'.")
  execSync("git config user.email '#{email}'")


# Adds remote origin URL with GitHub token so the script could push to the Dredd
# repository. GitHub token is encrypted in Dredd's .travis.yml.
ensureGitOrigin = ->
  if process.env.GITHUB_TOKEN
    console.log('Applying GitHub token.')
    repo = "https://#{process.env.GITHUB_TOKEN}@github.com/apiaryio/dredd.git"
    execSync("git remote set-url origin #{repo} #{DROP_OUTPUT}")


# Ensures that Git repository is set to given branch and it's clean.
cleanGit = (branch) ->
  execSync('git checkout ' + branch)
  execSync('git reset HEAD --hard')


# # Deletes given branches both locally and remotely on GitHub.
# deleteGitBranches = (branches) ->
#   for branch in branches
#     console.log("Deleting #{branch} from GitHub...")
#     execSync('git branch -D ' + branch)
#     execSync("git push origin -f --delete #{branch} #{DROP_OUTPUT}")


# Returns the latest tested Node.js version defined in the .travis.yml
# config file.
getLatestTestedNodeVersion = ->
  contents = fs.readFileSync(TRAVIS_CONFIG_FILE)
  config = yaml.safeLoad(contents)

  versions = config.node_js
  versions.sort((v1, v2) -> v2 - v1)
  return versions[0]


# Takes language version matrix in the .travis.yml config file and reduces
# it to just one language version. It chooses the one which represents
# the highest floating point number. If there is no version like that, it
# selects the first specified version.
reduceTestedVersions = (matrixName) ->
  console.log('reduce1')
  contents = fs.readFileSync(TRAVIS_CONFIG_FILE)
  console.log('reduce2', contents.toString())
  config = yaml.safeLoad(contents)

  console.log('reduce3')
  reduced = config[matrixName].map((version) -> parseFload(version))
  console.log('reduce4')
  reduced.sort((v1, v2) -> v2 - v1)
  console.log('reduce5')
  config[matrixName] = reduced[0] or config[matrixName][0]

  console.log('reduce6')
  fs.writeFileSync(TRAVIS_CONFIG_FILE, yaml.dump(config), 'utf-8')


# Retrieves full commit message.
getGitCommitMessage = (commitHash) ->
  getTrimmedStdout(execSync('git log --format=%B -n 1 ' + commitHash))


# Aborts this script in case it finds out that conditions to run this script
# are not satisfied. The script should run only if it was triggered by the
# tested commit being part of PR or by a keyword in the commit message.
abortIfNotTriggered = (testedNodeVersion, testedCommit, pullRequestId) ->
  reason = null

  # We do not want to run integration tests of hook handlers for every node
  # version in the matrix. One node version is perfectly enough as
  # the dependent builds will be performed on the default version Travis CI
  # provides anyway (.travis.yml of dependent repositories usually do not
  # specify node version, they care about Ruby, Python, ... versions).
  latestTestedNodeVersion = getLatestTestedNodeVersion()
  if testedNodeVersion isnt latestTestedNodeVersion
    reason = "They run only in builds with Node #{latestTestedNodeVersion}."
  else
    # Integration tests are triggered only if the tested commit is in PR or
    # it's message contains trigger keyword. If this is not the case, abort
    # the script.
    message = getGitCommitMessage(testedCommit)

    if pullRequestId
      console.log("Tested commit (#{testedCommit}) is part of the '##{pullRequestId}' PR.")
    else if message.toLowerCase().indexOf(TRIGGER_KEYWORD) isnt -1
      console.log("Message of tested commit (#{testedCommit}) contains '#{TRIGGER_KEYWORD}'.")
    else
      reason = "Tested commit (#{testedCommit}) isn't part of PR and its message doesn't contain keyword '#{TRIGGER_KEYWORD}'."

  # There is a reason to abort the script, so let's do it.
  if reason
    console.error('Skipping integration tests of hook handlers. ' + reason)
    process.exit(0)


################################################################################
##                                   MAIN                                     ##
################################################################################


integrationBranches = []
testedNodeVersion = process.env.TRAVIS_NODE_VERSION
testedBranch = process.env.TRAVIS_BRANCH
testedCommit = process.env.TRAVIS_COMMIT_RANGE.split('...')[1]
buildId = process.env.TRAVIS_BUILD_ID
pullRequestId = if process.env.TRAVIS_PULL_REQUEST isnt 'false' then process.env.TRAVIS_PULL_REQUEST else null


abortIfNotTriggered(testedNodeVersion, testedCommit, pullRequestId)
requireTravisCli()


ensureGitAuthor(testedCommit)
ensureGitOrigin()


JOBS.forEach(({name, repo, matrix}) ->
  id = if pullRequestId then "pr#{pullRequestId}/#{buildId}" else buildId
  integrationBranch = "dependent-build/#{id}/#{name}"
  integrationBranches.push(integrationBranch)
  console.log("Preparing branch #{integrationBranch}")

  # Prepare a special integration branch
  console.log(1)
  cleanGit(testedBranch)
  execSync('git checkout -B ' + integrationBranch)
  console.log(execSync('git branch').stdout)

  # Move contents of the root directory to the directory for linked Dredd and
  # commit this change.
  console.log(2)
  moveAllFilesTo(LINKED_DREDD_DIR, ['./.git', './.git/*', './scripts/*'])
  execSync('git add -A && git commit -m "chore: Moving Dredd to directory"')

  # Add Git remote with the repository being integrated. Merge its master
  # branch with what's in current branch. After this, we have contents of the
  # remote repo plus one extra directory, which contains current Dredd.
  console.log(3)
  execSync("git remote add #{name} #{repo} --fetch")
  execSync("git merge #{name}/master --no-edit")

  # Replace installation of Dredd in .travis.yml with a command which links
  # Dredd from the directory we created. Commit the change.
  unless replaceDreddInstallation()
    console.error('Could not find Dredd installation command in .travis.yml.', contents)
    process.exit(1)

  # Keep just the latest language version in the build matrix.
  console.log('ls: .')
  console.log(execSync('ls -al').stdout)
  console.log('ls: __dredd__')
  console.log(execSync('ls ./__dredd__ -al').stdout)
  console.log('ls: scripts')
  console.log(execSync('ls ./scripts -al').stdout)
  reduceTestedVersions(matrix)

  # Enhance the build configuration so it reports results back to PR and deletes
  # the branch afterwards.
  console.log(9)
  if pullRequestId
    console.log(10)
    execSync("travis encrypt GITHUB_TOKEN=#{process.env.GITHUB_TOKEN} --add #{DROP_OUTPUT}")
    console.log(11)
    request.post(
      url: 'https://api.github.com/repos/apiaryio/dredd/statuses/' + testedCommit
      headers:
        authorization: "token #{process.env.GITHUB_TOKEN}"
      body:
        state: 'pending'
        description: "The dependent build has been created"
        context: "continuous-integration/travis-ci/#{name}"
      json: true
    )
    # TRAVIS_TEST_RESULT=0 (success) / TRAVIS_TEST_RESULT=1 (broken)

  # Commit the changes.
  console.log(12)
  execSync('git commit -am "chore: Adjusted build configuration"')

  # Push the integration branch to GitHub and clean the repository.
  console.log("Pushing #{integrationBranch} to GitHub...")
  execSync("git push origin #{integrationBranch} -f #{DROP_OUTPUT}")
  cleanGit(testedBranch)
)
