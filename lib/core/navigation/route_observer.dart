import 'package:flutter/material.dart';

/// 앱 전역 RouteObserver.
///
/// `MaterialApp.navigatorObservers` 에 등록되어, 임의의 페이지(주로 HomePage)
/// 가 RouteAware 로 subscribe 하면 위로 push 된 페이지가 pop 될 때
/// `didPopNext()` 가 자동으로 호출된다.
///
/// ## 도입 배경
/// 사진 촬영 → 입력 → 저장 → pop 흐름에서 _reloadHomeCallback 이 누락되는
/// edge case (특히 _homeKey.currentState 가 일시적으로 null 인 경우) 에도
/// 홈이 무조건 다시 데이터를 읽도록 강제하기 위한 안전망.
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
