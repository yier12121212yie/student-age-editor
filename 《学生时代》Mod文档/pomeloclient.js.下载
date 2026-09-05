(function() {
  var isArray = Array.isArray;

  // compatible for ie browser
  if (isArray === undefined) {
    isArray = function(arr) {
      return Object.prototype.toString.call(arr) === '[object Array]';
    };
  }

  var root = this;

  function EventEmitter() {}

  if (typeof module !== 'undefined' && module.exports) {
    module.exports.EventEmitter = EventEmitter;
  } else {
    root = window;
    root.EventEmitter = EventEmitter;
  }

  // By default EventEmitters will print a warning if more than
  // 10 listeners are added to it. This is a useful default which
  // helps finding memory leaks.
  //
  // Obviously not all Emitters should be limited to 10. This function allows
  // that to be increased. Set to zero for unlimited.
  var defaultMaxListeners = 10;
  EventEmitter.prototype.setMaxListeners = function(n) {
    if (!this._events) this._events = {};
    this._maxListeners = n;
  };


  EventEmitter.prototype.emit = function() {
    var type = arguments[0];
    // If there is no 'error' event listener then throw.
    if (type === 'error') {
      if (!this._events || !this._events.error || (isArray(this._events.error) && !this._events.error.length)) {
        if (this.domain) {
          var er = arguments[1];
          er.domain_emitter = this;
          er.domain = this.domain;
          er.domain_thrown = false;
          this.domain.emit('error', er);
          return false;
        }

        if (arguments[1] instanceof Error) {
          throw arguments[1]; // Unhandled 'error' event
        } else {
          throw new Error("Uncaught, unspecified 'error' event.");
        }
        return false;
      }
    }

    if (!this._events) return false;
    var handler = this._events[type];
    if (!handler) return false;

    if (typeof handler == 'function') {
      if (this.domain) {
        this.domain.enter();
      }
      switch (arguments.length) {
        // fast cases
        case 1:
          handler.call(this);
          break;
        case 2:
          handler.call(this, arguments[1]);
          break;
        case 3:
          handler.call(this, arguments[1], arguments[2]);
          break;
          // slower
        default:
          var l = arguments.length;
          var args = new Array(l - 1);
          for (var i = 1; i < l; i++) args[i - 1] = arguments[i];
          handler.apply(this, args);
      }
      if (this.domain) {
        this.domain.exit();
      }
      return true;

    } else if (isArray(handler)) {
      if (this.domain) {
        this.domain.enter();
      }
      var l = arguments.length;
      var args = new Array(l - 1);
      for (var i = 1; i < l; i++) args[i - 1] = arguments[i];

      var listeners = handler.slice();
      for (var i = 0, l = listeners.length; i < l; i++) {
        listeners[i].apply(this, args);
      }
      if (this.domain) {
        this.domain.exit();
      }
      return true;

    } else {
      return false;
    }
  };

  EventEmitter.prototype.addListener = function(type, listener) {
    if ('function' !== typeof listener) {
      throw new Error('addListener only takes instances of Function');
    }

    if (!this._events) this._events = {};

    // To avoid recursion in the case that type == "newListeners"! Before
    // adding it to the listeners, first emit "newListeners".
    this.emit('newListener', type, typeof listener.listener === 'function' ? listener.listener : listener);

    if (!this._events[type]) {
      // Optimize the case of one listener. Don't need the extra array object.
      this._events[type] = listener;
    } else if (isArray(this._events[type])) {

      // If we've already got an array, just append.
      this._events[type].push(listener);

    } else {
      // Adding the second element, need to change to array.
      this._events[type] = [this._events[type], listener];

    }

    // Check for listener leak
    if (isArray(this._events[type]) && !this._events[type].warned) {
      var m;
      if (this._maxListeners !== undefined) {
        m = this._maxListeners;
      } else {
        m = defaultMaxListeners;
      }

      if (m && m > 0 && this._events[type].length > m) {
        this._events[type].warned = true;
        console.error('(node) warning: possible EventEmitter memory ' +
          'leak detected. %d listeners added. ' +
          'Use emitter.setMaxListeners() to increase limit.',
        this._events[type].length);
        console.trace();
      }
    }

    return this;
  };

  EventEmitter.prototype.on = EventEmitter.prototype.addListener;

  EventEmitter.prototype.once = function(type, listener) {
    if ('function' !== typeof listener) {
      throw new Error('.once only takes instances of Function');
    }

    var self = this;

    function g() {
      self.removeListener(type, g);
      listener.apply(this, arguments);
    };

    g.listener = listener;
    self.on(type, g);

    return this;
  };

  EventEmitter.prototype.removeListener = function(type, listener) {
    if ('function' !== typeof listener) {
      throw new Error('removeListener only takes instances of Function');
    }

    // does not use listeners(), so no side effect of creating _events[type]
    if (!this._events || !this._events[type]) return this;

    var list = this._events[type];

    if (isArray(list)) {
      var position = -1;
      for (var i = 0, length = list.length; i < length; i++) {
        if (list[i] === listener || (list[i].listener && list[i].listener === listener)) {
          position = i;
          break;
        }
      }

      if (position < 0) return this;
      list.splice(position, 1);
    } else if (list === listener || (list.listener && list.listener === listener)) {
      delete this._events[type];
    }

    return this;
  };

  EventEmitter.prototype.removeAllListeners = function(type) {
    if (arguments.length === 0) {
      this._events = {};
      return this;
    }

    var events = this._events && this._events[type];
    if (!events) return this;

    if (isArray(events)) {
      events.splice(0);
    } else {
      this._events[type] = null;
    }

    return this;
  };

  EventEmitter.prototype.listeners = function(type) {
    if (!this._events) this._events = {};
    if (!this._events[type]) this._events[type] = [];
    if (!isArray(this._events[type])) {
      this._events[type] = [this._events[type]];
    }
    return this._events[type];
  }
})();

(function() {
  if (typeof Object.create !== 'function') {
    Object.create = function(o) {
      function F() {}
      F.prototype = o;
      return new F();
    };
  }

  var root = window;
  var pomelo = Object.create(EventEmitter.prototype); // object extend from object
  root.pomelo = pomelo;
  var socket = null;
  var id = 1;
  var callbacks = {};
  var route = 'web-connector.messageHandler.';
  var isRegister = false;
  var success = 200;
  var register_ack = 'register';
  var bind_ack = 'bind';
  var regBind_ack = 'registerAndBind';
  var cancelBind_ack = 'cancelBind';
  var specify = 'specify';
  var reconnectMessage = 'reconnectMessage';
  var message_store = {};
  var heartbeat_interval = 1000 * 60;
  var heartbeat_timer;
  var current_user;
  var current_domain;
  var cacheMessageIds = [];
  var cacheSize = 100;

  /**
   * Initialize connection to server side
   *
   * @param {String} host server ip address
   * @param {Number} port server port
   * @param {Function} cb callback function
   * @memberOf pomelo
   */
  pomelo.init = function(host, port, reconnect, cb) {
    var url = 'https://' + host;
    if (port) {
      url += ':' + port;
    }

    // try to connect
    var params;
    if(reconnect) {
      params = {'force new connection': true, reconnect: true};
    } else {
      params = {'force new connection': true, reconnect: false};
    }

    socket = io.connect(url, params);

    // connect on server side successfully
    socket.on('connect', function() {
      console.log('[pomeloclient.init] websocket connected!');
      cb();
    });

    socket.on('reconnect', function() {
      pomelo.emit('reconnect');
    });

    // receive socket message
    socket.on('message', function(data) {
      console.log('receive message from server: ', data);
      message_store = {};
      if (typeof data === 'string') {
        data = JSON.parse(data);
      }
      if (data instanceof Array) {
        processMessageBatch(data);
      } else {
        processMessage(data);
        emitMessage();
      }
    });

    // encounter connection error
    socket.on('error', function(err) {
      cb(err);
    });

    // disconnect event
    socket.on('disconnect', function(reason) {
      isRegister = false;
      pomelo.emit('disconnect', reason);
    });
  };

  /**
   * Send request to server side
   *
   * @param {String} method request type include: bind & cancelBind & getOnlineUser
   * @param {Object} opts request parameters
   * @param {Function} cb callback function
   * @private
   */
  var request = function(method, opts, cb) {
    // if method is not exist
    if (!method) {
      console.error('request message error with no method.');
      return;
    }
    id++;
    callbacks[id] = cb;
    sendMsg(method, id, opts);
  };

  /**
   * Send message to server side with no callback
   *
   * @param {String} method notify type include: heartbeat
   * @param {Object} msg notify parameters
   * @private
   */
  var notify = function(method, msg) {
    // if method is not exist
    if (!method) {
      console.error('notify message error with no method.');
      return;
    }
    sendMsg(method, 0, msg);
  };

  /**
   * Encode message and send by socket
   *
   * @param {String} method request type include: bind & cancelBind & getOnlineUser
   * @param {Object} msg message need to send
   * @private
   */
  var sendMsg = function(method, msgId, msg) {
    // assembly request route
    var path = route + method;
    var rs = {
      id: msgId,
      route: path,
      msg: msg
    };
    var sg = JSON.stringify(rs);
    console.log('client send message to server: ', sg);
    socket.send(sg);
  };

  /**
   * Process message in batch
   *
   * @param {Array} msgs message array
   * @private
   */
  var processMessageBatch = function(msgs) {
    for (var i = 0, l = msgs.length; i < l; i++) {
      processMessage(msgs[i]);
    }
    emitMessage();
  };

  /**
   * Emit messages according to message route
   *
   * @private
   */
  var emitMessage = function() {
    for (var key in message_store) {
      pomelo.emit(key, message_store[key]);
    }
  };

  /**
   * Process message
   *
   * @param {Object} msg message need to process
   * @private
   */
  var processMessage = function(msg) {
    if (msg.id) {
      //if have a id then find the callback function with the request
      var cb = callbacks[msg.id];
      delete callbacks[msg.id];

      if (typeof cb !== 'function') {
        console.log('[pomeloclient.processMessage] cb is not a function for request ' + msg.id);
        return;
      }

      cb(msg.body);

      // check if it is register ack message & judge if success
      if (msg.body.type === register_ack && msg.body.code == success) {
        isRegister = true;
      }

      // bind user successfully and set heartbeat
      if ((msg.body.type === bind_ack || msg.body.type === regBind_ack) && msg.body.code == success) {
        heartbeat_timer = setInterval(function() {
          notify('heartbeat', {
            flag: 'online',
            domain: current_domain,
            user: current_user
          });
        }, heartbeat_interval);
      }
      // cancel bind successfully and clear heartbeat interval
      if (msg.body.type === cancelBind_ack && msg.body.code == success) {
        clearInterval(heartbeat_timer);
      }

      return;
    }
    //if no id then it should be a server push message
    else {
      if (!filterMessage(msg)) {
        //duplicated messages
        return;
      }
      if (!message_store[msg.route]) {
        if(msg.body instanceof Array) {
          if(msg.route === specify) {
            msg.route = reconnectMessage;
          }
          message_store[msg.route] = msg.body;
        } else {
          message_store[msg.route] = [msg.body];
        }
      } else {
        var arr = message_store[msg.route];
        if(msg.body instanceof Array) {
          var messages = msg.body;
          for(var i=0; i<messages.length; i++) {
            arr.push(messages[i]);
          }
        } else {
          arr.push(msg.body);
        }
        message_store[msg.route] = arr;
      }
    }
  };

  /**
   * Filter duplicated messages
   *
   * @param {Object} message messages need to filter
   * @private
   */
  var filterMessage = function(message) {
    var msgs = message.body;
    var ids = [];
    var results = {};
    if(msgs instanceof Array) {
      for(var i=0; i<msgs.length; i++) {
        var id = msgs[i].msgId;
        ids.push(id);
      }
      var duplicatedIds = checkMessage(ids);
      if(duplicatedIds.length !== 0) {
        return false;
      } else {
      cacheMessageIds = cacheMessageIds.concat(ids);
      if(cacheMessageIds.length > cacheSize) {
        var length = cacheMessageIds - cacheSize;
        for(var i=0; i<length; i++) {
          cacheMessageIds.shift();
        }
      }
    }
  } 
  return true;
};

  /**
   * Check if messages are duplicated
   *
   * @param {Array} ids array of message ids
   * @private
   */
  var checkMessage = function(ids) {
    var array = [];
    for(var i=0; i<cacheMessageIds.length; i++) {
      var id = cacheMessageIds[i];
      for(var j=0; j<ids.length; j++) {
        if(ids[j] === id) {
          array.push(id);
        }
      }
    }
    return array;
  };

  /**
   * Send domain information to server side
   *
   * @param {Object} opts include domain: product domain & productKey: product key
   * @param  {Function} cb callback function return data include code: response code
   * @memberOf pomelo
   */
  pomelo.register = function(opts, cb) {
    request('register', opts, cb);
  };

  /**
   * Send user information to server side
   *
   * @param {Object} opts include domain: product domain & user: user id & signature: user signature & expire_time: signature expire time & nonce: random string & productKey: product key
   * @param  {Function} cb callback function return data include code: response code & user: user id
   * @memberOf pomelo
   */
  pomelo.bind = function(opts, cb) {
    if (isRegister) {
      current_domain = opts.domain;
      current_user = opts.user;
      request('bind', opts, cb);
    } else {
      console.log('cannot bind without registration.');
    }
  };

  /**
   * Send domain & user information to server side
   *
   * @param {Object} opts include domain: product domain & user: user id & signature: user signature & expire_time: signature expire time & nonce: random string & productKey: product key
   * @param  {Function} cb callback function return data include code: response code & user: user id
   * @memberOf pomelo
   */
  pomelo.registerAndBind = function(opts, cb) {
    current_domain = opts.domain;
    current_user = opts.user;
    request('registerAndBind', opts, cb);
  };

  /**
   * Delete user information on server side
   *
   * @param {Object} opts include domain: product domain & user: user id
   * @param  {Function} cb callback function return data include code: response code & user: user id
   * @memberOf pomelo
   */
  pomelo.cancelBind = function(opts, cb) {
    current_domain = null;
    current_user = null;
    request('cancelBind', opts, cb);
  };

  /**
   * Query users status
   *
   * @param {Object} opts include domain: product domain & ids: user id array
   * @param  {Function} cb callback function return data like: {test1: 0, test2: 1}
   * @memberOf pomelo
   */
  pomelo.getOnlineUser = function(opts, cb) {
    request('getOnlineUser', opts, cb);
  };

  /**
   * Disconnect from server side
   *
   * @memberOf pomelo
   */
  pomelo.disconnect = function() {
    if (socket) {
      socket.disconnect();
      socket = null;
    }
  };

  /**
   * Ack message to server side
   *
   * @memberOf pomelo
   */
  pomelo.ackMessage = function(domain, msgs) {
    var msgIds = '';
    var types = '';
    var message = {};
    var user;
    for(var i=0; i<msgs.length; i++) {
      var data = msgs[i];
      if(!user) {
        user = data.user;
      }
      msgIds += data.msgId;
      types += data.type;
      if(i !== msgs.length-1) {
        msgIds += ';';
        types += ';';
      }
    }
    var message = {
      user: user,
      msgIds: msgIds,
      types: types,
      domain: domain
    };
    notify('ack', message);
  };

})();