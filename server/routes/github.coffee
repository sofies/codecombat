log = require 'winston'
errors = require '../commons/errors'
mongoose = require 'mongoose'
config = require('../../server_config')
request = require 'request'
User = require '../users/User'

module.exports.setup = (app) ->
  app.get '/github/auth_callback', (req, res) ->
    return errors.forbidden res unless req.user # need identity
    response =
      code: req.query.code
      client_id: config.github.client_id
      client_secret: config.github.client_secret
    headers =
      Accept: 'application/json'
    request.post {uri: 'https://github.com/login/oauth/access_token', json: response, headers: headers}, (err, r, response) ->
      log.error err if err?
      if response.error or err? # If anything goes wrong just 404
        res.send 404, response.error_description or err
      else
        {access_token, token_type, scope} = response
        headers =
          Accept: 'application/json'
          Authorization: "token #{access_token}"
          'User-Agent': if config.isProduction then 'CodeCombat' else 'CodeCombatDev'
        request.get {uri: 'https://api.github.com/user', headers: headers}, (err, r, response) ->
          return log.error err if err?
          githubUser = JSON.parse response
          emailLower = githubUser.email.toLowerCase()

          # GitHub users can change emails
          User.findOne {$or: [{emailLower: emailLower}, {githubID: githubUser.id}]}, (err, user) ->
            return errors.serverError res, err if err?
            wrapup = (err, user) ->
              return errors.serverError res, err if err?
              req.login (user), (err) ->
                return errors.serverError res, err if err?
                res.redirect '/'
            unless user
              req.user.set 'email', githubUser.email
              req.user.set 'githubID', githubUser.id
              req.user.save wrapup
            else if user.get('githubID') isnt githubUser.id # Add or replace githubID to/with existing user
              user.set 'githubID', githubUser.id
              user.save wrapup
            else if user.get('emailLower') isnt emailLower # Existing GitHub user with us changed email
              user.update {email: githubUser.email}, (err) -> wrapup err, user
            else # All good you've been here before
              wrapup null, user
