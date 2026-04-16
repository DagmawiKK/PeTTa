!(import! &self (library lib_import))
!(import_prolog_functions_from_file (library lib_http.pl)
   (http_get http_head http_options http_delete
    http_post http_put http_patch http_request
    http_submit http_poll http_await http_cancel
    http_is_ok http_status http_body http_error_kind))

(= (http-get $url) (http_get $url))
(= (http-head $url) (http_head $url))
(= (http-options $url) (http_options $url))
(= (http-delete $url) (http_delete $url))
(= (http-post $url $body) (http_post $url $body))
(= (http-put $url $body) (http_put $url $body))
(= (http-patch $url $body) (http_patch $url $body))

(= (http-request $url $method $body $opts)
   (http_request $url $method $body $opts))

(= (http-submit $url $method $body $opts)
   (http_submit $url $method $body $opts))
(= (http-poll $job-id) (http_poll $job-id))
(= (http-await $job-id $timeout-seconds) (http_await $job-id $timeout-seconds))
(= (http-cancel $job-id) (http_cancel $job-id))

(= (http-ok? $result) (http_is_ok $result))
(= (http-status $result) (http_status $result))
(= (http-body $result) (http_body $result))
(= (http-error-kind $result) (http_error_kind $result))
