/*
 Copyright 2015 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd
 Copyright 2019 The Matrix.org Foundation C.I.C

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXKAuthenticationViewController.h"

#import "MXKAuthInputsEmailCodeBasedView.h"
#import "MXKAuthInputsPasswordBasedView.h"

#import "MXKAccountManager.h"

#import "NSBundle+MatrixKit.h"

#import <AFNetworking/AFNetworking.h>

@interface MXKAuthenticationViewController ()
{
    /**
     The matrix REST client used to make matrix API requests.
     */
    MXRestClient *mxRestClient;
    
    /**
     Current request in progress.
     */
    MXHTTPOperation *mxCurrentOperation;
    
    /**
     The MXKAuthInputsView class or a sub-class used when logging in.
     */
    Class loginAuthInputsViewClass;
    
    /**
     The MXKAuthInputsView class or a sub-class used when registering.
     */
    Class registerAuthInputsViewClass;
    
    /**
     The MXKAuthInputsView class or a sub-class used to handle forgot password case.
     */
    Class forgotPasswordAuthInputsViewClass;
    
    /**
     Customized block used to handle unrecognized certificate (nil by default).
     */
    MXHTTPClientOnUnrecognizedCertificate onUnrecognizedCertificateCustomBlock;
    
    /**
     The current authentication fallback URL (if any).
     */
    NSString *authenticationFallback;
    
    /**
     The cancel button added in navigation bar when fallback page is opened.
     */
    UIBarButtonItem *cancelFallbackBarButton;
    
    /**
     The timer used to postpone the registration when the authentication is pending (for example waiting for email validation)
     */
    NSTimer* registrationTimer;

    /**
     Identity Server discovery.
     */
    MXAutoDiscovery *autoDiscovery;

    MXHTTPOperation *checkIdentityServerOperation;
}

/**
 The identity service used to make identity server API requests.
 */
@property (nonatomic) MXIdentityService *identityService;

@end

@implementation MXKAuthenticationViewController

#pragma mark - Class methods

+ (UINib *)nib
{
    return [UINib nibWithNibName:NSStringFromClass([MXKAuthenticationViewController class])
                          bundle:[NSBundle bundleForClass:[MXKAuthenticationViewController class]]];
}

+ (instancetype)authenticationViewController
{
    return [[[self class] alloc] initWithNibName:NSStringFromClass([MXKAuthenticationViewController class])
                                          bundle:[NSBundle bundleForClass:[MXKAuthenticationViewController class]]];
}

#pragma mark -

- (void)finalizeInit
{
    [super finalizeInit];
    
    // Set initial auth type
    _authType = MXKAuthenticationTypeLogin;
    
    _deviceDisplayName = nil;
    
    // Initialize authInputs view classes
    loginAuthInputsViewClass = MXKAuthInputsPasswordBasedView.class;
    registerAuthInputsViewClass = nil; // No registration flow is supported yet
    forgotPasswordAuthInputsViewClass = nil;
}

#pragma mark -

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    // Check whether the view controller has been pushed via storyboard
    if (!_authenticationScrollView)
    {
        // Instantiate view controller objects
        [[[self class] nib] instantiateWithOwner:self options:nil];
    }
    
    self.authFallbackWebView = [[MXKAuthenticationFallbackWebView alloc] initWithFrame:self.authFallbackWebViewContainer.bounds];
    [self.authFallbackWebViewContainer addSubview:self.authFallbackWebView];
    [self.authFallbackWebView.leadingAnchor constraintEqualToAnchor:self.authFallbackWebViewContainer.leadingAnchor constant:0].active = YES;
    [self.authFallbackWebView.trailingAnchor constraintEqualToAnchor:self.authFallbackWebViewContainer.trailingAnchor constant:0].active = YES;
    [self.authFallbackWebView.topAnchor constraintEqualToAnchor:self.authFallbackWebViewContainer.topAnchor constant:0].active = YES;
    [self.authFallbackWebView.bottomAnchor constraintEqualToAnchor:self.authFallbackWebViewContainer.bottomAnchor constant:0].active = YES;
    
    // Load welcome image from MatrixKit asset bundle
    self.welcomeImageView.image = [NSBundle mxk_imageFromMXKAssetsBundleWithName:@"logoHighRes"];

    _authenticationScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    _subTitleLabel.numberOfLines = 0;
    
    _submitButton.enabled = NO;
    _authSwitchButton.enabled = YES;
    
    _homeServerTextField.text = _defaultHomeServerUrl;
    _identityServerTextField.text = _defaultIdentityServerUrl;

    // Hide the identity server by default
    [self setIdentityServerHidden:YES];

    // Create here REST client (if homeserver is defined)
    [self updateRESTClient];
    
    // Localize labels
    _homeServerLabel.text = [NSBundle mxk_localizedStringForKey:@"login_home_server_title"];
    _homeServerTextField.placeholder = [NSBundle mxk_localizedStringForKey:@"login_server_url_placeholder"];
    _homeServerInfoLabel.text = [NSBundle mxk_localizedStringForKey:@"login_home_server_info"];
    _identityServerLabel.text = [NSBundle mxk_localizedStringForKey:@"login_identity_server_title"];
    _identityServerTextField.placeholder = [NSBundle mxk_localizedStringForKey:@"login_server_url_placeholder"];
    _identityServerInfoLabel.text = [NSBundle mxk_localizedStringForKey:@"login_identity_server_info"];
    [_cancelAuthFallbackButton setTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] forState:UIControlStateNormal];
    [_cancelAuthFallbackButton setTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] forState:UIControlStateHighlighted];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTextFieldChange:) name:UITextFieldTextDidChangeNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [self dismissKeyboard];
    
    // close any opened alert
    if (alert)
    {
        [alert dismissViewControllerAnimated:NO completion:nil];
        alert = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNetworkingReachabilityDidChangeNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UITextFieldTextDidChangeNotification object:nil];
}

#pragma mark - Override MXKViewController

- (void)onKeyboardShowAnimationComplete
{
    // Report the keyboard view in order to track keyboard frame changes
    // TODO define inputAccessoryView for each text input
    // and report the inputAccessoryView.superview of the firstResponder in self.keyboardView.
}

- (void)setKeyboardHeight:(CGFloat)keyboardHeight
{
    // Deduce the bottom inset for the scroll view (Don't forget the potential tabBar)
    CGFloat scrollViewInsetBottom = keyboardHeight - self.bottomLayoutGuide.length;
    // Check whether the keyboard is over the tabBar
    if (scrollViewInsetBottom < 0)
    {
        scrollViewInsetBottom = 0;
    }
    
    UIEdgeInsets insets = self.authenticationScrollView.contentInset;
    insets.bottom = scrollViewInsetBottom;
    self.authenticationScrollView.contentInset = insets;
}

- (void)destroy
{
    self.authInputsView = nil;
    
    if (registrationTimer)
    {
        [registrationTimer invalidate];
        registrationTimer = nil;
    }
    
    if (mxCurrentOperation)
    {
        [mxCurrentOperation cancel];
        mxCurrentOperation = nil;
    }

    [self cancelIdentityServerCheck];

    [mxRestClient close];
    mxRestClient = nil;

    authenticationFallback = nil;
    cancelFallbackBarButton = nil;
    
    [super destroy];
}

#pragma mark - Class methods

- (void)registerAuthInputsViewClass:(Class)authInputsViewClass forAuthType:(MXKAuthenticationType)authType
{
    // Sanity check: accept only MXKAuthInputsView classes or sub-classes
    NSParameterAssert([authInputsViewClass isSubclassOfClass:MXKAuthInputsView.class]);
    
    if (authType == MXKAuthenticationTypeLogin)
    {
        loginAuthInputsViewClass = authInputsViewClass;
    }
    else if (authType == MXKAuthenticationTypeRegister)
    {
        registerAuthInputsViewClass = authInputsViewClass;
    }
    else if (authType == MXKAuthenticationTypeForgotPassword)
    {
        forgotPasswordAuthInputsViewClass = authInputsViewClass;
    }
}

- (void)setAuthType:(MXKAuthenticationType)authType
{
    if (_authType != authType)
    {
        _authType = authType;
        
        // Cancel external registration parameters if any
        _externalRegistrationParameters = nil;
        
        // Remove the current inputs view
        self.authInputsView = nil;
        
        isPasswordReseted = NO;
        
        [self.authInputsContainerView bringSubviewToFront: _authenticationActivityIndicator];
        [_authenticationActivityIndicator startAnimating];
    }
    
    // Restore user interaction
    self.userInteractionEnabled = YES;
    
    if (authType == MXKAuthenticationTypeLogin)
    {
        _subTitleLabel.hidden = YES;
        [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"login"] forState:UIControlStateNormal];
        [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"login"] forState:UIControlStateHighlighted];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"create_account"] forState:UIControlStateNormal];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"create_account"] forState:UIControlStateHighlighted];
        
        // Update supported authentication flow and associated information (defined in authentication session)
        [self refreshAuthenticationSession];
    }
    else if (authType == MXKAuthenticationTypeRegister)
    {
        _subTitleLabel.hidden = NO;
        _subTitleLabel.text = [NSBundle mxk_localizedStringForKey:@"login_create_account"];
        [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"sign_up"] forState:UIControlStateNormal];
        [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"sign_up"] forState:UIControlStateHighlighted];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateNormal];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateHighlighted];
        
        // Update supported authentication flow and associated information (defined in authentication session)
        [self refreshAuthenticationSession];
    }
    else if (authType == MXKAuthenticationTypeForgotPassword)
    {
        _subTitleLabel.hidden = YES;
        
        if (isPasswordReseted)
        {
            [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateNormal];
            [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateHighlighted];
        }
        else
        {
            [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"submit"] forState:UIControlStateNormal];
            [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"submit"] forState:UIControlStateHighlighted];
            
            [self refreshForgotPasswordSession];
        }
        
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateNormal];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateHighlighted];
    }

    [self checkIdentityServer];
}

- (void)setAuthInputsView:(MXKAuthInputsView *)authInputsView
{
    // Here a new view will be loaded, hide first subviews which depend on auth flow
    _submitButton.hidden = YES;
    _noFlowLabel.hidden = YES;
    _retryButton.hidden = YES;
    
    if (_authInputsView)
    {
        [_authInputsView removeObserver:self forKeyPath:@"viewHeightConstraint.constant"];
        
        if ([NSLayoutConstraint respondsToSelector:@selector(deactivateConstraints:)])
        {
            [NSLayoutConstraint deactivateConstraints:_authInputsView.constraints];
        }
        else
        {
            [_authInputsContainerView removeConstraints:_authInputsView.constraints];
        }
        
        [_authInputsView removeFromSuperview];
        _authInputsView.delegate = nil;
        [_authInputsView destroy];
        _authInputsView = nil;
    }
    
    _authInputsView = authInputsView;
    
    CGFloat previousInputsContainerViewHeight = _authInputContainerViewHeightConstraint.constant;
    
    if (_authInputsView)
    {
        _authInputsView.translatesAutoresizingMaskIntoConstraints = NO;
        [_authInputsContainerView addSubview:_authInputsView];
        
        _authInputsView.delegate = self;
        
        _submitButton.hidden = NO;
        _authInputsView.hidden = NO;
        
        _authInputContainerViewHeightConstraint.constant = _authInputsView.viewHeightConstraint.constant;
        
        NSLayoutConstraint* topConstraint = [NSLayoutConstraint constraintWithItem:_authInputsContainerView
                                                                         attribute:NSLayoutAttributeTop
                                                                         relatedBy:NSLayoutRelationEqual
                                                                            toItem:_authInputsView
                                                                         attribute:NSLayoutAttributeTop
                                                                        multiplier:1.0f
                                                                          constant:0.0f];
        
        
        NSLayoutConstraint* leadingConstraint = [NSLayoutConstraint constraintWithItem:_authInputsContainerView
                                                                             attribute:NSLayoutAttributeLeading
                                                                             relatedBy:NSLayoutRelationEqual
                                                                                toItem:_authInputsView
                                                                             attribute:NSLayoutAttributeLeading
                                                                            multiplier:1.0f
                                                                              constant:0.0f];
        
        NSLayoutConstraint* trailingConstraint = [NSLayoutConstraint constraintWithItem:_authInputsContainerView
                                                                              attribute:NSLayoutAttributeTrailing
                                                                              relatedBy:NSLayoutRelationEqual
                                                                                 toItem:_authInputsView
                                                                              attribute:NSLayoutAttributeTrailing
                                                                             multiplier:1.0f
                                                                               constant:0.0f];
        
        
        if ([NSLayoutConstraint respondsToSelector:@selector(activateConstraints:)])
        {
            [NSLayoutConstraint activateConstraints:@[topConstraint, leadingConstraint, trailingConstraint]];
        }
        else
        {
            [_authInputsContainerView addConstraint:topConstraint];
            [_authInputsContainerView addConstraint:leadingConstraint];
            [_authInputsContainerView addConstraint:trailingConstraint];
        }
        
        [_authInputsView addObserver:self forKeyPath:@"viewHeightConstraint.constant" options:0 context:nil];
    }
    else
    {
        // No input fields are displayed
        _authInputContainerViewHeightConstraint.constant = _authInputContainerViewMinHeightConstraint.constant;
    }
    
    [self.view layoutIfNeeded];
    
    // Refresh content view height by considering the updated height of inputs container
    _contentViewHeightConstraint.constant += (_authInputContainerViewHeightConstraint.constant - previousInputsContainerViewHeight);
}

- (void)setDefaultHomeServerUrl:(NSString *)defaultHomeServerUrl
{
    _defaultHomeServerUrl = defaultHomeServerUrl;
    
    if (!_homeServerTextField.text.length)
    {
        [self setHomeServerTextFieldText:defaultHomeServerUrl];
    }
}

- (void)setDefaultIdentityServerUrl:(NSString *)defaultIdentityServerUrl
{
    _defaultIdentityServerUrl = defaultIdentityServerUrl;
    
    if (!_identityServerTextField.text.length)
    {
        [self setIdentityServerTextFieldText:defaultIdentityServerUrl];
    }
}

- (void)setHomeServerTextFieldText:(NSString *)homeServerUrl
{
    if (!homeServerUrl.length)
    {
        // Force refresh with default value
        homeServerUrl = _defaultHomeServerUrl;
    }
    
    _homeServerTextField.text = homeServerUrl;
    
    if (!mxRestClient || ![mxRestClient.homeserver isEqualToString:homeServerUrl])
    {
        [self updateRESTClient];
        
        if (_authType == MXKAuthenticationTypeLogin || _authType == MXKAuthenticationTypeRegister)
        {
            // Restore default UI
            self.authType = _authType;
        }
        else
        {
            // Refresh the IS anyway
            [self checkIdentityServer];
        }
    }
}

- (void)setIdentityServerTextFieldText:(NSString *)identityServerUrl
{    
    _identityServerTextField.text = identityServerUrl;
    
    [self updateIdentityServerURL:identityServerUrl];
}

- (void)updateIdentityServerURL:(NSString*)url
{
    if (![self.identityService.identityServer isEqualToString:url])
    {
        if (url.length)
        {
            self.identityService = [[MXIdentityService alloc] initWithIdentityServer:url accessToken:nil andHomeserverRestClient:mxRestClient];
        }
        else
        {
            self.identityService = nil;
        }
    }
    
    [mxRestClient setIdentityServer:url.length ? url : nil];
}

- (void)setIdentityServerHidden:(BOOL)hidden
{
    _identityServerContainer.hidden = hidden;
}

- (void)checkIdentityServer
{
    [self cancelIdentityServerCheck];

    // Hide the field while checking data
    [self setIdentityServerHidden:YES];

    NSString *homeserver = mxRestClient.homeserver;

    // First, fetch the IS advertised by the HS
    if (homeserver)
    {
        MXLogDebug(@"[MXKAuthenticationVC] checkIdentityServer for homeserver %@", homeserver);

        autoDiscovery = [[MXAutoDiscovery alloc] initWithUrl:homeserver];

        MXWeakify(self);
        checkIdentityServerOperation = [autoDiscovery findClientConfig:^(MXDiscoveredClientConfig * _Nonnull discoveredClientConfig) {
            MXStrongifyAndReturnIfNil(self);

            NSString *identityServer = discoveredClientConfig.wellKnown.identityServer.baseUrl;
            MXLogDebug(@"[MXKAuthenticationVC] checkIdentityServer: Identity server: %@", identityServer);

            if (identityServer)
            {
                // Apply the provided IS
                [self setIdentityServerTextFieldText:identityServer];
            }

            // Then, check if the HS needs an IS for running
            MXWeakify(self);
            MXHTTPOperation *operation = [self checkIdentityServerRequirementWithCompletion:^(BOOL identityServerRequired) {
                
                MXStrongifyAndReturnIfNil(self);

                self->checkIdentityServerOperation = nil;

                // Show the field only if an IS is required so that the user can customise it
                [self setIdentityServerHidden:!identityServerRequired];
            }];

            if (operation)
            {
                [self->checkIdentityServerOperation mutateTo:operation];
            }
            else
            {
                self->checkIdentityServerOperation = nil;
            }

            self->autoDiscovery = nil;

        } failure:^(NSError *error) {
            MXStrongifyAndReturnIfNil(self);

            // No need to report this error to the end user
            // There will be already an error about failing to get the auth flow from the HS
            MXLogDebug(@"[MXKAuthenticationVC] checkIdentityServer. Error: %@", error);

            self->autoDiscovery = nil;
        }];
    }
}

- (void)cancelIdentityServerCheck
{
    if (checkIdentityServerOperation)
    {
        [checkIdentityServerOperation cancel];
        checkIdentityServerOperation = nil;
    }
}

- (MXHTTPOperation*)checkIdentityServerRequirementWithCompletion:(void (^)(BOOL identityServerRequired))completion
{
    MXHTTPOperation *operation;

    if (_authType == MXKAuthenticationTypeLogin)
    {
        // The identity server is only required for registration and password reset
        // It is then stored in the user account data
        completion(NO);
    }
    else
    {
        operation = [mxRestClient supportedMatrixVersions:^(MXMatrixVersions *matrixVersions) {

            MXLogDebug(@"[MXKAuthenticationVC] checkIdentityServerRequirement: %@", matrixVersions.doesServerRequireIdentityServerParam ? @"YES": @"NO");
            completion(matrixVersions.doesServerRequireIdentityServerParam);

        } failure:^(NSError *error) {
            // No need to report this error to the end user
            // There will be already an error about failing to get the auth flow from the HS
            MXLogDebug(@"[MXKAuthenticationVC] checkIdentityServerRequirement. Error: %@", error);
        }];
    }

    return operation;
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled
{
    _submitButton.enabled = (userInteractionEnabled && _authInputsView.areAllRequiredFieldsSet);
    _authSwitchButton.enabled = userInteractionEnabled;
    
    _homeServerTextField.enabled = userInteractionEnabled;
    _identityServerTextField.enabled = userInteractionEnabled;
    
    _userInteractionEnabled = userInteractionEnabled;
}

- (void)refreshAuthenticationSession
{
    // Remove reachability observer
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNetworkingReachabilityDidChangeNotification object:nil];
    
    // Cancel potential request in progress
    [mxCurrentOperation cancel];
    mxCurrentOperation = nil;
    
    // Reset potential authentication fallback url
    authenticationFallback = nil;
    
    if (mxRestClient)
    {
        if (_authType == MXKAuthenticationTypeLogin)
        {
            mxCurrentOperation = [mxRestClient getLoginSession:^(MXAuthenticationSession* authSession) {
                
                [self handleAuthenticationSession:authSession];
                
            } failure:^(NSError *error) {
                
                [self onFailureDuringMXOperation:error];
                
            }];
        }
        else if (_authType == MXKAuthenticationTypeRegister)
        {
            mxCurrentOperation = [mxRestClient getRegisterSession:^(MXAuthenticationSession* authSession){
                
                [self handleAuthenticationSession:authSession];
                
            } failure:^(NSError *error){
                
                [self onFailureDuringMXOperation:error];
                
            }];
        }
        else
        {
            // Not supported for other types
            MXLogDebug(@"[MXKAuthenticationVC] refreshAuthenticationSession is ignored");
        }
    }
}

- (void)handleAuthenticationSession:(MXAuthenticationSession *)authSession
{
    mxCurrentOperation = nil;
    
    [_authenticationActivityIndicator stopAnimating];
    
    // Check whether fallback is defined, and retrieve the right input view class.
    Class authInputsViewClass;
    if (_authType == MXKAuthenticationTypeLogin)
    {
        authenticationFallback = [mxRestClient loginFallback];
        authInputsViewClass = loginAuthInputsViewClass;
        
    }
    else if (_authType == MXKAuthenticationTypeRegister)
    {
        authenticationFallback = [mxRestClient registerFallback];
        authInputsViewClass = registerAuthInputsViewClass;
    }
    else
    {
        // Not supported for other types
        MXLogDebug(@"[MXKAuthenticationVC] handleAuthenticationSession is ignored");
        return;
    }
    
    MXKAuthInputsView *authInputsView = nil;
    if (authInputsViewClass)
    {
        // Instantiate a new auth inputs view, except if the current one is already an instance of this class.
        if (self.authInputsView && self.authInputsView.class == authInputsViewClass)
        {
            // Use the current view
            authInputsView = self.authInputsView;
        }
        else
        {
            authInputsView = [authInputsViewClass authInputsView];
        }
    }
    
    if (authInputsView)
    {
        // Apply authentication session on inputs view
        if ([authInputsView setAuthSession:authSession withAuthType:_authType] == NO)
        {
            MXLogDebug(@"[MXKAuthenticationVC] Received authentication settings are not supported");
            authInputsView = nil;
        }
        else if (!_softLogoutCredentials)
        {
            // If all listed flows in this authentication session are not supported we suggest using the fallback page.
            if (authenticationFallback.length && authInputsView.authSession.flows.count == 0)
            {
                MXLogDebug(@"[MXKAuthenticationVC] No supported flow, suggest using fallback page");
                authInputsView = nil;
            }
            else if (authInputsView.authSession.flows.count != authSession.flows.count)
            {
                MXLogDebug(@"[MXKAuthenticationVC] The authentication session contains at least one unsupported flow");
            }
        }
    }
    
    if (authInputsView)
    {
        // Check whether the current view must be replaced
        if (self.authInputsView != authInputsView)
        {
            // Refresh layout
            self.authInputsView = authInputsView;
        }
        
        // Refresh user interaction
        self.userInteractionEnabled = _userInteractionEnabled;
        
        // Check whether an external set of parameters have been defined to pursue a registration
        if (self.externalRegistrationParameters)
        {
            if ([authInputsView setExternalRegistrationParameters:self.externalRegistrationParameters])
            {
                // Launch authentication now
                [self onButtonPressed:_submitButton];
            }
            else
            {
                [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                
                _externalRegistrationParameters = nil;
                
                // Restore login screen on failure
                self.authType = MXKAuthenticationTypeLogin;
            }
        }

        if (_softLogoutCredentials)
        {
            [authInputsView setSoftLogoutCredentials:_softLogoutCredentials];
        }
    }
    else
    {
        // Remove the potential auth inputs view
        self.authInputsView = nil;
        
        // Cancel external registration parameters if any
        _externalRegistrationParameters = nil;
        
        // Notify user that no flow is supported
        if (_authType == MXKAuthenticationTypeLogin)
        {
            _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"login_error_do_not_support_login_flows"];
        }
        else
        {
            _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"login_error_registration_is_not_supported"];
        }
        MXLogDebug(@"[MXKAuthenticationVC] Warning: %@", _noFlowLabel.text);
        
        if (authenticationFallback.length)
        {
            [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"login_use_fallback"] forState:UIControlStateNormal];
            [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"login_use_fallback"] forState:UIControlStateNormal];
        }
        else
        {
            [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"retry"] forState:UIControlStateNormal];
            [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"retry"] forState:UIControlStateNormal];
        }
        
        _noFlowLabel.hidden = NO;
        _retryButton.hidden = NO;
    }
}

- (void)setExternalRegistrationParameters:(NSDictionary*)parameters
{
    if (parameters.count)
    {
        MXLogDebug(@"[MXKAuthenticationVC] setExternalRegistrationParameters");
        
        // Cancel the current operation if any.
        [self cancel];
        
        // Load the view controller’s view if it has not yet been loaded.
        // This is required before updating view's textfields (homeserver url...)
        [self loadViewIfNeeded];
        
        // Force register mode
        self.authType = MXKAuthenticationTypeRegister;
        
        // Apply provided homeserver if any
        id hs_url = parameters[@"hs_url"];
        NSString *homeserverURL = nil;
        if (hs_url && [hs_url isKindOfClass:NSString.class])
        {
            homeserverURL = hs_url;
        }
        [self setHomeServerTextFieldText:homeserverURL];
        
        // Apply provided identity server if any
        id is_url = parameters[@"is_url"];
        NSString *identityURL = nil;
        if (is_url && [is_url isKindOfClass:NSString.class])
        {
            identityURL = is_url;
        }
        [self setIdentityServerTextFieldText:identityURL];
        
        // Disable user interaction
        self.userInteractionEnabled = NO;
        
        // Cancel potential request in progress
        [mxCurrentOperation cancel];
        mxCurrentOperation = nil;
        
        // Remove the current auth inputs view
        self.authInputsView = nil;
        
        // Set external parameters and trigger a refresh (the parameters will be taken into account during [handleAuthenticationSession:])
        _externalRegistrationParameters = parameters;
        [self refreshAuthenticationSession];
    }
    else
    {
        MXLogDebug(@"[MXKAuthenticationVC] reset externalRegistrationParameters");
        _externalRegistrationParameters = nil;
        
        // Restore default UI
        self.authType = _authType;
    }
}

- (void)setSoftLogoutCredentials:(MXCredentials *)softLogoutCredentials
{
    MXLogDebug(@"[MXKAuthenticationVC] setSoftLogoutCredentials");

    // Cancel the current operation if any.
    [self cancel];

    // Load the view controller’s view if it has not yet been loaded.
    // This is required before updating view's textfields (homeserver url...)
    [self loadViewIfNeeded];

    // Force register mode
    self.authType = MXKAuthenticationTypeLogin;

    [self setHomeServerTextFieldText:softLogoutCredentials.homeServer];
    [self setIdentityServerTextFieldText:softLogoutCredentials.identityServer];

    // Cancel potential request in progress
    [mxCurrentOperation cancel];
    mxCurrentOperation = nil;

    // Remove the current auth inputs view
    self.authInputsView = nil;

    // Set parameters and trigger a refresh (the parameters will be taken into account during [handleAuthenticationSession:])
    _softLogoutCredentials = softLogoutCredentials;
    [self refreshAuthenticationSession];
}

- (void)setOnUnrecognizedCertificateBlock:(MXHTTPClientOnUnrecognizedCertificate)onUnrecognizedCertificateBlock
{
    onUnrecognizedCertificateCustomBlock = onUnrecognizedCertificateBlock;
}

- (void)isUserNameInUse:(void (^)(BOOL isUserNameInUse))callback
{
    mxCurrentOperation = [mxRestClient isUserNameInUse:self.authInputsView.userId callback:^(BOOL isUserNameInUse) {
        
        self->mxCurrentOperation = nil;
        
        if (callback)
        {
            callback (isUserNameInUse);
        }
        
    }];
}

- (void)testUserRegistration:(void (^)(MXError *mxError))callback
{
    mxCurrentOperation = [mxRestClient testUserRegistration:self.authInputsView.userId callback:callback];
}

- (IBAction)onButtonPressed:(id)sender
{
    [self dismissKeyboard];
    
    if (sender == _submitButton)
    {
        // Disable user interaction to prevent multiple requests
        self.userInteractionEnabled = NO;
        
        // Check parameters validity
        NSString *errorMsg = [self.authInputsView validateParameters];
        if (errorMsg)
        {
            [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:errorMsg}]];
        }
        else
        {
            [self.authInputsContainerView bringSubviewToFront: _authenticationActivityIndicator];
            
            // Launch the authentication according to its type
            if (_authType == MXKAuthenticationTypeLogin)
            {
                // Prepare the parameters dict
                [self.authInputsView prepareParameters:^(NSDictionary *parameters, NSError *error) {
                    
                    if (parameters && self->mxRestClient)
                    {
                        [self->_authenticationActivityIndicator startAnimating];
                        [self loginWithParameters:parameters];
                    }
                    else
                    {
                        MXLogDebug(@"[MXKAuthenticationVC] Failed to prepare parameters");
                        [self onFailureDuringAuthRequest:error];
                    }
                    
                }];
            }
            else if (_authType == MXKAuthenticationTypeRegister)
            {
                // Check here the availability of the userId
                if (self.authInputsView.userId.length)
                {
                    [_authenticationActivityIndicator startAnimating];
                    
                    if (self.authInputsView.password.length)
                    {
                        // Trigger here a register request in order to associate the filled userId and password to the current session id
                        // This will check the availability of the userId at the same time
                        NSDictionary *parameters = @{@"auth": @{},
                                                     @"username": self.authInputsView.userId,
                                                     @"password": self.authInputsView.password,
                                                     @"bind_email": @(NO),
                                                     @"initial_device_display_name":self.deviceDisplayName
                                                     };
                        
                        mxCurrentOperation = [mxRestClient registerWithParameters:parameters success:^(NSDictionary *JSONResponse) {
                            
                            // Unexpected case where the registration succeeds without any other stages
                            MXLoginResponse *loginResponse;
                            MXJSONModelSetMXJSONModel(loginResponse, MXLoginResponse, JSONResponse);

                            MXCredentials *credentials = [[MXCredentials alloc] initWithLoginResponse:loginResponse
                                                                                andDefaultCredentials:self->mxRestClient.credentials];
                            
                            // Sanity check
                            if (!credentials.userId || !credentials.accessToken)
                            {
                                [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                            }
                            else
                            {
                                MXLogDebug(@"[MXKAuthenticationVC] Registration succeeded");

                                // Report the certificate trusted by user (if any)
                                credentials.allowedCertificate = self->mxRestClient.allowedCertificate;
                                
                                [self onSuccessfulLogin:credentials];
                            }
                            
                        } failure:^(NSError *error) {
                            
                            self->mxCurrentOperation = nil;
                            
                            // An updated authentication session should be available in response data in case of unauthorized request.
                            NSDictionary *JSONResponse = nil;
                            if (error.userInfo[MXHTTPClientErrorResponseDataKey])
                            {
                                JSONResponse = error.userInfo[MXHTTPClientErrorResponseDataKey];
                            }
                            
                            if (JSONResponse)
                            {
                                MXAuthenticationSession *authSession = [MXAuthenticationSession modelFromJSON:JSONResponse];
                                
                                [self->_authenticationActivityIndicator stopAnimating];
                                
                                // Update session identifier
                                self.authInputsView.authSession.session = authSession.session;
                                
                                // Launch registration by preparing parameters dict
                                [self.authInputsView prepareParameters:^(NSDictionary *parameters, NSError *error) {
                                    
                                    if (parameters && self->mxRestClient)
                                    {
                                        [self->_authenticationActivityIndicator startAnimating];
                                        [self registerWithParameters:parameters];
                                    }
                                    else
                                    {
                                        MXLogDebug(@"[MXKAuthenticationVC] Failed to prepare parameters");
                                        [self onFailureDuringAuthRequest:error];
                                    }
                                    
                                }];
                            }
                            else
                            {
                                [self onFailureDuringAuthRequest:error];
                            }
                        }];
                    }
                    else
                    {
                        [self isUserNameInUse:^(BOOL isUserNameInUse) {
                            
                            if (isUserNameInUse)
                            {
                                MXLogDebug(@"[MXKAuthenticationVC] User name is already use");
                                [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"auth_username_in_use"]}]];
                            }
                            else
                            {
                                [self->_authenticationActivityIndicator stopAnimating];
                               
                                // Launch registration by preparing parameters dict
                                [self.authInputsView prepareParameters:^(NSDictionary *parameters, NSError *error) {
                                    
                                    if (parameters && self->mxRestClient)
                                    {
                                        [self->_authenticationActivityIndicator startAnimating];
                                        [self registerWithParameters:parameters];
                                    }
                                    else
                                    {
                                        MXLogDebug(@"[MXKAuthenticationVC] Failed to prepare parameters");
                                        [self onFailureDuringAuthRequest:error];
                                    }
                                    
                                }];
                            }
                            
                        }];
                    }
                }
                else if (self.externalRegistrationParameters)
                {
                    // Launch registration by preparing parameters dict
                    [self.authInputsView prepareParameters:^(NSDictionary *parameters, NSError *error) {
                        
                        if (parameters && self->mxRestClient)
                        {
                            [self->_authenticationActivityIndicator startAnimating];
                            [self registerWithParameters:parameters];
                        }
                        else
                        {
                            MXLogDebug(@"[MXKAuthenticationVC] Failed to prepare parameters");
                            [self onFailureDuringAuthRequest:error];
                        }
                        
                    }];
                }
                else
                {
                    MXLogDebug(@"[MXKAuthenticationVC] User name is missing");
                    [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"auth_invalid_user_name"]}]];
                }
            }
            else if (_authType == MXKAuthenticationTypeForgotPassword)
            {
                // Check whether the password has been reseted
                if (isPasswordReseted)
                {
                    // Return to login screen
                    self.authType = MXKAuthenticationTypeLogin;
                }
                else
                {
                    // Prepare the parameters dict
                    [self.authInputsView prepareParameters:^(NSDictionary *parameters, NSError *error) {
                        
                        if (parameters && self->mxRestClient)
                        {
                            [self->_authenticationActivityIndicator startAnimating];
                            [self resetPasswordWithParameters:parameters];
                        }
                        else
                        {
                            MXLogDebug(@"[MXKAuthenticationVC] Failed to prepare parameters");
                            [self onFailureDuringAuthRequest:error];
                        }
                        
                    }];
                }
            }
        }
    }
    else if (sender == _authSwitchButton)
    {
        if (_authType == MXKAuthenticationTypeLogin)
        {
            self.authType = MXKAuthenticationTypeRegister;
        }
        else
        {
            self.authType = MXKAuthenticationTypeLogin;
        }
    }
    else if (sender == _retryButton)
    {
        if (authenticationFallback)
        {
            [self showAuthenticationFallBackView:authenticationFallback];
        }
        else
        {
            [self refreshAuthenticationSession];
        }
    }
    else if (sender == _cancelAuthFallbackButton)
    {
        // Hide fallback webview
        [self hideRegistrationFallbackView];
    }
}

- (void)cancel
{
    MXLogDebug(@"[MXKAuthenticationVC] cancel");
    
    // Cancel external registration parameters if any
    _externalRegistrationParameters = nil;
    
    if (registrationTimer)
    {
        [registrationTimer invalidate];
        registrationTimer = nil;
    }
    
    // Cancel request in progress
    if (mxCurrentOperation)
    {
        [mxCurrentOperation cancel];
        mxCurrentOperation = nil;
    }
    
    [_authenticationActivityIndicator stopAnimating];
    self.userInteractionEnabled = YES;
    
    // Reset potential completed stages
    self.authInputsView.authSession.completed = nil;
    
    // Update authentication inputs view to return in initial step
    [self.authInputsView setAuthSession:self.authInputsView.authSession withAuthType:_authType];
}

- (void)onFailureDuringAuthRequest:(NSError *)error
{
    mxCurrentOperation = nil;
    [_authenticationActivityIndicator stopAnimating];
    self.userInteractionEnabled = YES;
    
    // Ignore connection cancellation error
    if (([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled))
    {
        MXLogDebug(@"[MXKAuthenticationVC] Auth request cancelled");
        return;
    }
    
    MXLogDebug(@"[MXKAuthenticationVC] Auth request failed: %@", error);
    
    // Cancel external registration parameters if any
    _externalRegistrationParameters = nil;
    
    // Translate the error code to a human message
    NSString *title = error.localizedFailureReason;
    if (!title)
    {
        if (self.authType == MXKAuthenticationTypeLogin)
        {
            title = [NSBundle mxk_localizedStringForKey:@"login_error_title"];
        }
        else if (self.authType == MXKAuthenticationTypeRegister)
        {
            title = [NSBundle mxk_localizedStringForKey:@"register_error_title"];
        }
        else
        {
            title = [NSBundle mxk_localizedStringForKey:@"error"];
        }
    }
    NSString* message = error.localizedDescription;
    NSDictionary* dict = error.userInfo;
    
    // detect if it is a Matrix SDK issue
    if (dict)
    {
        NSString* localizedError = [dict valueForKey:@"error"];
        NSString* errCode = [dict valueForKey:@"errcode"];
        
        if (localizedError.length > 0)
        {
            message = localizedError;
        }
        
        if (errCode)
        {
            if ([errCode isEqualToString:kMXErrCodeStringForbidden])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_forbidden"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringUnknownToken])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_unknown_token"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringBadJSON])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_bad_json"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringNotJSON])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_not_json"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringLimitExceeded])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_limit_exceeded"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringUserInUse])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_user_in_use"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringLoginEmailURLNotYet])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_login_email_not_yet"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringResourceLimitExceeded])
            {
                [self showResourceLimitExceededError:dict onAdminContactTapped:nil];
                return;
            }
            else if (!message.length)
            {
                message = errCode;
            }
        }
    }
    
    // Alert user
    if (alert)
    {
        [alert dismissViewControllerAnimated:NO completion:nil];
    }
    
    alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"ok"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                
                                                self->alert = nil;
                                                
                                            }]];
    
    
    [self presentViewController:alert animated:YES completion:nil];
    
    // Update authentication inputs view to return in initial step
    [self.authInputsView setAuthSession:self.authInputsView.authSession withAuthType:_authType];
    if (self.softLogoutCredentials)
    {
        self.authInputsView.softLogoutCredentials = self.softLogoutCredentials;
    }
}

- (void)showResourceLimitExceededError:(NSDictionary *)errorDict onAdminContactTapped:(void (^)(NSURL *adminContact))onAdminContactTapped
{
    mxCurrentOperation = nil;
    [_authenticationActivityIndicator stopAnimating];
    self.userInteractionEnabled = YES;

    // Alert user
    if (alert)
    {
        [alert dismissViewControllerAnimated:NO completion:nil];
    }

    // Parse error data
    NSString *limitType, *adminContactString;
    NSURL *adminContact;

    MXJSONModelSetString(limitType, errorDict[kMXErrorResourceLimitExceededLimitTypeKey]);
    MXJSONModelSetString(adminContactString, errorDict[kMXErrorResourceLimitExceededAdminContactKey]);

    if (adminContactString)
    {
        adminContact = [NSURL URLWithString:adminContactString];
    }

    NSString *title = [NSBundle mxk_localizedStringForKey:@"login_error_resource_limit_exceeded_title"];

    // Build the message content
    NSMutableString *message = [NSMutableString new];
    if ([limitType isEqualToString:kMXErrorResourceLimitExceededLimitTypeMonthlyActiveUserValue])
    {
        [message appendString:[NSBundle mxk_localizedStringForKey:@"login_error_resource_limit_exceeded_message_monthly_active_user"]];
    }
    else
    {
        [message appendString:[NSBundle mxk_localizedStringForKey:@"login_error_resource_limit_exceeded_message_default"]];
    }

    [message appendString:[NSBundle mxk_localizedStringForKey:@"login_error_resource_limit_exceeded_message_contact"]];

    // Build the alert
    alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];

    MXWeakify(self);
    if (adminContact && onAdminContactTapped)
    {
        [alert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"login_error_resource_limit_exceeded_contact_button"]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * action)
                          {
                              MXStrongifyAndReturnIfNil(self);
                              self->alert = nil;

                              // Let the system handle the URI
                              // It could be something like "mailto: server.admin@example.com"
                              onAdminContactTapped(adminContact);
                          }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"cancel"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action)
                      {
                          MXStrongifyAndReturnIfNil(self);
                          self->alert = nil;
                      }]];

    [self presentViewController:alert animated:YES completion:nil];

    // Update authentication inputs view to return in initial step
    [self.authInputsView setAuthSession:self.authInputsView.authSession withAuthType:_authType];
}

- (void)onSuccessfulLogin:(MXCredentials*)credentials
{
    mxCurrentOperation = nil;
    [_authenticationActivityIndicator stopAnimating];
    self.userInteractionEnabled = YES;

    if (self.softLogoutCredentials)
    {
        // Hydrate the account with the new access token
        MXKAccount *account = [[MXKAccountManager sharedManager] accountForUserId:self.softLogoutCredentials.userId];
        [[MXKAccountManager sharedManager] hydrateAccount:account withCredentials:credentials];

        if (_delegate)
        {
            [_delegate authenticationViewController:self didLogWithUserId:credentials.userId];
        }
    }
    // Sanity check: check whether the user is not already logged in with this id
    else if ([[MXKAccountManager sharedManager] accountForUserId:credentials.userId])
    {
        //Alert user
        __weak typeof(self) weakSelf = self;
        
        if (alert)
        {
            [alert dismissViewControllerAnimated:NO completion:nil];
        }
        
        alert = [UIAlertController alertControllerWithTitle:[NSBundle mxk_localizedStringForKey:@"login_error_already_logged_in"] message:nil preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"ok"]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * action) {
                                                    
                                                    // We remove the authentication view controller.
                                                    typeof(self) self = weakSelf;
                                                    self->alert = nil;
                                                    [self withdrawViewControllerAnimated:YES completion:nil];
                                                    
                                                }]];
        
        
        [self presentViewController:alert animated:YES completion:nil];
    }
    else
    {
        // Report the new account in account manager
        if (!credentials.identityServer)
        {
            credentials.identityServer = _identityServerTextField.text;
        }
        MXKAccount *account = [[MXKAccount alloc] initWithCredentials:credentials];
        account.identityServerURL = credentials.identityServer;
        
        [[MXKAccountManager sharedManager] addAccount:account andOpenSession:YES];
        
        if (_delegate)
        {
            [_delegate authenticationViewController:self didLogWithUserId:credentials.userId];
        }
    }
}

- (MXHTTPOperation *)currentHttpOperation
{
    return mxCurrentOperation;
}

#pragma mark - Privates

- (NSString *)deviceDisplayName
{
    if (_deviceDisplayName)
    {
        return _deviceDisplayName;
    }
    
#if TARGET_OS_IPHONE
    NSString *deviceName = [[UIDevice currentDevice].model isEqualToString:@"iPad"] ? [NSBundle mxk_localizedStringForKey:@"login_tablet_device"] : [NSBundle mxk_localizedStringForKey:@"login_mobile_device"];
#elif TARGET_OS_OSX
    NSString *deviceName = [NSBundle mxk_localizedStringForKey:@"login_desktop_device"];
#endif
    
    return deviceName;
}

- (void)refreshForgotPasswordSession
{
    [_authenticationActivityIndicator stopAnimating];
    
    MXKAuthInputsView *authInputsView = nil;
    if (forgotPasswordAuthInputsViewClass)
    {
        // Instantiate a new auth inputs view, except if the current one is already an instance of this class.
        if (self.authInputsView && self.authInputsView.class == forgotPasswordAuthInputsViewClass)
        {
            // Use the current view
            authInputsView = self.authInputsView;
        }
        else
        {
            authInputsView = [forgotPasswordAuthInputsViewClass authInputsView];
        }
    }
    
    if (authInputsView)
    {
        // Update authentication inputs view to return in initial step
        [authInputsView setAuthSession:nil withAuthType:MXKAuthenticationTypeForgotPassword];
        
        // Check whether the current view must be replaced
        if (self.authInputsView != authInputsView)
        {
            // Refresh layout
            self.authInputsView = authInputsView;
        }
        
        // Refresh user interaction
        self.userInteractionEnabled = _userInteractionEnabled;
    }
    else
    {
        // Remove the potential auth inputs view
        self.authInputsView = nil;
        
        _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"login_error_forgot_password_is_not_supported"];
        
        MXLogDebug(@"[MXKAuthenticationVC] Warning: %@", _noFlowLabel.text);
        
        _noFlowLabel.hidden = NO;
    }
}

- (void)updateRESTClient
{
    NSString *homeserverURL = _homeServerTextField.text;
    
    if (homeserverURL.length)
    {
        // Check change
        if ([homeserverURL isEqualToString:mxRestClient.homeserver] == NO)
        {
            mxRestClient = [[MXRestClient alloc] initWithHomeServer:homeserverURL andOnUnrecognizedCertificateBlock:^BOOL(NSData *certificate) {
                
                // Check first if the app developer provided its own certificate handler.
                if (self->onUnrecognizedCertificateCustomBlock)
                {
                    return self->onUnrecognizedCertificateCustomBlock (certificate);
                }
                
                // Else prompt the user by displaying a fingerprint (SHA256) of the certificate.
                __block BOOL isTrusted;
                dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                
                NSString *title = [NSBundle mxk_localizedStringForKey:@"ssl_could_not_verify"];
                NSString *homeserverURLStr = [NSString stringWithFormat:[NSBundle mxk_localizedStringForKey:@"ssl_homeserver_url"], homeserverURL];
                NSString *fingerprint = [NSString stringWithFormat:[NSBundle mxk_localizedStringForKey:@"ssl_fingerprint_hash"], @"SHA256"];
                NSString *certFingerprint = [certificate mx_SHA256AsHexString];
                
                NSString *msg = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@", [NSBundle mxk_localizedStringForKey:@"ssl_cert_not_trust"], [NSBundle mxk_localizedStringForKey:@"ssl_cert_new_account_expl"], homeserverURLStr, fingerprint, certFingerprint, [NSBundle mxk_localizedStringForKey:@"ssl_only_accept"]];
                
                if (self->alert)
                {
                    [self->alert dismissViewControllerAnimated:NO completion:nil];
                }
                
                self->alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
                
                [self->alert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"cancel"]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction * action) {
                                                            
                                                            self->alert = nil;
                                                            isTrusted = NO;
                                                            dispatch_semaphore_signal(semaphore);
                                                            
                                                        }]];
                
                [self->alert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"ssl_trust"]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction * action) {
                                                            
                                                            self->alert = nil;
                                                            isTrusted = YES;
                                                            dispatch_semaphore_signal(semaphore);
                                                            
                                                        }]];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self presentViewController:self->alert animated:YES completion:nil];
                });
                
                dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
                
                if (!isTrusted)
                {
                    // Cancel request in progress
                    [self->mxCurrentOperation cancel];
                    self->mxCurrentOperation = nil;
                    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNetworkingReachabilityDidChangeNotification object:nil];

                    [self->_authenticationActivityIndicator stopAnimating];
                }
                
                return isTrusted;
            }];
            
            if (_identityServerTextField.text.length)
            {
                [self updateIdentityServerURL:self.identityServerTextField.text];
            }
        }
    }
    else
    {
        [mxRestClient close];
        mxRestClient = nil;
    }
}

- (void)loginWithParameters:(NSDictionary*)parameters
{
    // Add the device name
    NSMutableDictionary *theParameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
    theParameters[@"initial_device_display_name"] = self.deviceDisplayName;
    
    mxCurrentOperation = [mxRestClient login:theParameters success:^(NSDictionary *JSONResponse) {

        MXLoginResponse *loginResponse;
        MXJSONModelSetMXJSONModel(loginResponse, MXLoginResponse, JSONResponse);

        MXCredentials *credentials = [[MXCredentials alloc] initWithLoginResponse:loginResponse
                                                            andDefaultCredentials:self->mxRestClient.credentials];
        
        // Sanity check
        if (!credentials.userId || !credentials.accessToken)
        {
            [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
        }
        else
        {
            MXLogDebug(@"[MXKAuthenticationVC] Login process succeeded");

            // Report the certificate trusted by user (if any)
            credentials.allowedCertificate = self->mxRestClient.allowedCertificate;
            
            [self onSuccessfulLogin:credentials];
        }
        
    } failure:^(NSError *error) {
        
        [self onFailureDuringAuthRequest:error];
        
    }];
}

- (void)registerWithParameters:(NSDictionary*)parameters
{
    if (registrationTimer)
    {
        [registrationTimer invalidate];
        registrationTimer = nil;
    }
    
    // Add the device name
    NSMutableDictionary *theParameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
    theParameters[@"initial_device_display_name"] = self.deviceDisplayName;
    
    mxCurrentOperation = [mxRestClient registerWithParameters:theParameters success:^(NSDictionary *JSONResponse) {
        
        MXLoginResponse *loginResponse;
        MXJSONModelSetMXJSONModel(loginResponse, MXLoginResponse, JSONResponse);

        MXCredentials *credentials = [[MXCredentials alloc] initWithLoginResponse:loginResponse
                                                            andDefaultCredentials:self->mxRestClient.credentials];
        
        // Sanity check
        if (!credentials.userId || !credentials.accessToken)
        {
            [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
        }
        else
        {
            MXLogDebug(@"[MXKAuthenticationVC] Registration succeeded");

            // Report the certificate trusted by user (if any)
            credentials.allowedCertificate = self->mxRestClient.allowedCertificate;
            
            [self onSuccessfulLogin:credentials];
        }
        
    } failure:^(NSError *error) {
        
        self->mxCurrentOperation = nil;
        
        // Check whether the authentication is pending (for example waiting for email validation)
        MXError *mxError = [[MXError alloc] initWithNSError:error];
        if (mxError && [mxError.errcode isEqualToString:kMXErrCodeStringUnauthorized])
        {
            MXLogDebug(@"[MXKAuthenticationVC] Wait for email validation");
            
            // Postpone a new attempt in 10 sec
            self->registrationTimer = [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(registrationTimerFireMethod:) userInfo:parameters repeats:NO];
        }
        else
        {
            // The completed stages should be available in response data in case of unauthorized request.
            NSDictionary *JSONResponse = nil;
            if (error.userInfo[MXHTTPClientErrorResponseDataKey])
            {
                JSONResponse = error.userInfo[MXHTTPClientErrorResponseDataKey];
            }
            
            if (JSONResponse)
            {
                MXAuthenticationSession *authSession = [MXAuthenticationSession modelFromJSON:JSONResponse];
                
                if (authSession.completed)
                {
                    [self->_authenticationActivityIndicator stopAnimating];
                    
                    // Update session identifier in case of change
                    self.authInputsView.authSession.session = authSession.session;
                    
                    [self.authInputsView updateAuthSessionWithCompletedStages:authSession.completed didUpdateParameters:^(NSDictionary *parameters, NSError *error) {
                        
                        if (parameters)
                        {
                            MXLogDebug(@"[MXKAuthenticationVC] Pursue registration");
                            
                            [self->_authenticationActivityIndicator startAnimating];
                            [self registerWithParameters:parameters];
                        }
                        else
                        {
                            MXLogDebug(@"[MXKAuthenticationVC] Failed to update parameters");
                            
                            [self onFailureDuringAuthRequest:error];
                        }
                        
                    }];
                    
                    return;
                }
                
                [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
            }
            else
            {
                [self onFailureDuringAuthRequest:error];
            }
        }
    }];
}

- (void)registrationTimerFireMethod:(NSTimer *)timer
{
    if (timer == registrationTimer && timer.isValid)
    {
        MXLogDebug(@"[MXKAuthenticationVC] Retry registration");
        [self registerWithParameters:registrationTimer.userInfo];
    }
}

- (void)resetPasswordWithParameters:(NSDictionary*)parameters
{
    mxCurrentOperation = [mxRestClient resetPasswordWithParameters:parameters success:^() {
        
        MXLogDebug(@"[MXKAuthenticationVC] Reset password succeeded");
        
        self->mxCurrentOperation = nil;
        [self->_authenticationActivityIndicator stopAnimating];
        
        self->isPasswordReseted = YES;
        
        // Force UI update to refresh submit button title.
        self.authType = self->_authType;
        
        // Refresh the authentication inputs view on success.
        [self.authInputsView nextStep];
        
    } failure:^(NSError *error) {
        
        MXError *mxError = [[MXError alloc] initWithNSError:error];
        if (mxError && [mxError.errcode isEqualToString:kMXErrCodeStringUnauthorized])
        {
            MXLogDebug(@"[MXKAuthenticationVC] Forgot Password: wait for email validation");
            
            self->mxCurrentOperation = nil;
            [self->_authenticationActivityIndicator stopAnimating];
            
            if (self->alert)
            {
                [self->alert dismissViewControllerAnimated:NO completion:nil];
            }
            
            self->alert = [UIAlertController alertControllerWithTitle:[NSBundle mxk_localizedStringForKey:@"error"] message:[NSBundle mxk_localizedStringForKey:@"auth_reset_password_error_unauthorized"] preferredStyle:UIAlertControllerStyleAlert];
            
            [self->alert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"ok"]
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * action) {
                                                        
                                                        self->alert = nil;
                                                        
                                                    }]];
            
            
            [self presentViewController:self->alert animated:YES completion:nil];
        }
        else if (mxError && [mxError.errcode isEqualToString:kMXErrCodeStringNotFound])
        {
            MXLogDebug(@"[MXKAuthenticationVC] Forgot Password: not found");
            
            NSMutableDictionary *userInfo;
            if (error.userInfo)
            {
                userInfo = [NSMutableDictionary dictionaryWithDictionary:error.userInfo];
            }
            else
            {
                userInfo = [NSMutableDictionary dictionary];
            }
            userInfo[NSLocalizedDescriptionKey] = [NSBundle mxk_localizedStringForKey:@"auth_reset_password_error_not_found"];
            
            [self onFailureDuringAuthRequest:[NSError errorWithDomain:kMXNSErrorDomain code:0 userInfo:userInfo]];
        }
        else
        {
            [self onFailureDuringAuthRequest:error];
        }
        
    }];
}

- (void)onFailureDuringMXOperation:(NSError*)error
{
    mxCurrentOperation = nil;
    
    [_authenticationActivityIndicator stopAnimating];
    
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)
    {
        // Ignore this error
        MXLogDebug(@"[MXKAuthenticationVC] flows request cancelled");
        return;
    }
    
    MXLogDebug(@"[MXKAuthenticationVC] Failed to get %@ flows: %@", (_authType == MXKAuthenticationTypeLogin ? @"Login" : @"Register"), error);
    
    // Cancel external registration parameters if any
    _externalRegistrationParameters = nil;
    
    // Alert user
    NSString *title = [error.userInfo valueForKey:NSLocalizedFailureReasonErrorKey];
    if (!title)
    {
        title = [NSBundle mxk_localizedStringForKey:@"error"];
    }
    NSString *msg = [error.userInfo valueForKey:NSLocalizedDescriptionKey];
    
    if (alert)
    {
        [alert dismissViewControllerAnimated:NO completion:nil];
    }
    
    alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"dismiss"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                
                                                self->alert = nil;
                                                
                                            }]];
    
    
    [self presentViewController:alert animated:YES completion:nil];
    
    // Handle specific error code here
    if ([error.domain isEqualToString:NSURLErrorDomain])
    {
        // Check network reachability
        if (error.code == NSURLErrorNotConnectedToInternet)
        {
            // Add reachability observer in order to launch a new request when network will be available
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onReachabilityStatusChange:) name:AFNetworkingReachabilityDidChangeNotification object:nil];
        }
        else if (error.code == kCFURLErrorTimedOut)
        {
            // Send a new request in 2 sec
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self refreshAuthenticationSession];
            });
        }
        else
        {
            // Remove the potential auth inputs view
            self.authInputsView = nil;
        }
    }
    else
    {
        // Remove the potential auth inputs view
        self.authInputsView = nil;
    }
    
    if (!_authInputsView)
    {
        // Display failure reason
        _noFlowLabel.hidden = NO;
        _noFlowLabel.text = [error.userInfo valueForKey:NSLocalizedDescriptionKey];
        if (!_noFlowLabel.text.length)
        {
            _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"login_error_no_login_flow"];
        }
        [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"retry"] forState:UIControlStateNormal];
        [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"retry"] forState:UIControlStateNormal];
        _retryButton.hidden = NO;
    }
}

- (void)onReachabilityStatusChange:(NSNotification *)notif
{
    AFNetworkReachabilityManager *reachabilityManager = [AFNetworkReachabilityManager sharedManager];
    AFNetworkReachabilityStatus status = reachabilityManager.networkReachabilityStatus;
    
    if (status == AFNetworkReachabilityStatusReachableViaWiFi || status == AFNetworkReachabilityStatusReachableViaWWAN)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshAuthenticationSession];
        });
    }
    else if (status == AFNetworkReachabilityStatusNotReachable)
    {
        _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"network_error_not_reachable"];
    }
}

#pragma mark - Keyboard handling

- (void)dismissKeyboard
{
    // Hide the keyboard
    [_authInputsView dismissKeyboard];
    [_homeServerTextField resignFirstResponder];
    [_identityServerTextField resignFirstResponder];
}

#pragma mark - UITextField delegate

- (void)onTextFieldChange:(NSNotification *)notif
{
    _submitButton.enabled = _authInputsView.areAllRequiredFieldsSet;

    if (notif.object == _homeServerTextField)
    {
        // If any, the current request is obsolete
        [self cancelIdentityServerCheck];

        [self setIdentityServerHidden:YES];
    }
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField
{
    if (textField == _homeServerTextField)
    {
        // Cancel supported AuthFlow refresh if a request is in progress
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNetworkingReachabilityDidChangeNotification object:nil];
        
        if (mxCurrentOperation)
        {
            // Cancel potential request in progress
            [mxCurrentOperation cancel];
            mxCurrentOperation = nil;
        }
    }

    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    if (textField == _homeServerTextField)
    {
        [self setHomeServerTextFieldText:textField.text];
    }
    else if (textField == _identityServerTextField)
    {
        [self setIdentityServerTextFieldText:textField.text];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField
{
    if (textField.returnKeyType == UIReturnKeyDone)
    {
        // "Done" key has been pressed
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark - AuthInputsViewDelegate delegate

- (void)authInputsView:(MXKAuthInputsView*)authInputsView presentAlertController:(UIAlertController*)inputsAlert
{
    [self dismissKeyboard];
    [self presentViewController:inputsAlert animated:YES completion:nil];
}

- (void)authInputsViewDidPressDoneKey:(MXKAuthInputsView *)authInputsView
{
    if (_submitButton.isEnabled)
    {
        // Launch authentication now
        [self onButtonPressed:_submitButton];
    }
}

- (MXRestClient *)authInputsViewThirdPartyIdValidationRestClient:(MXKAuthInputsView *)authInputsView
{
    return mxRestClient;
}

- (MXIdentityService *)authInputsViewThirdPartyIdValidationIdentityService:(MXIdentityService *)authInputsView
{
    return self.identityService;
}

#pragma mark - Authentication Fallback

- (void)showAuthenticationFallBackView
{
    [self showAuthenticationFallBackView:authenticationFallback];
}

- (void)showAuthenticationFallBackView:(NSString*)fallbackPage
{
    _authenticationScrollView.hidden = YES;
    _authFallbackContentView.hidden = NO;
    
    // Add a cancel button in case of navigation controller use.
    if (self.navigationController)
    {
        if (!cancelFallbackBarButton)
        {
            cancelFallbackBarButton = [[UIBarButtonItem alloc] initWithTitle:[NSBundle mxk_localizedStringForKey:@"login_leave_fallback"] style:UIBarButtonItemStylePlain target:self action:@selector(hideRegistrationFallbackView)];
        }
        
        // Add cancel button in right bar items
        NSArray *rightBarButtonItems = self.navigationItem.rightBarButtonItems;
        self.navigationItem.rightBarButtonItems = rightBarButtonItems ? [rightBarButtonItems arrayByAddingObject:cancelFallbackBarButton] : @[cancelFallbackBarButton];
    }

    if (self.softLogoutCredentials)
    {
        // Add device_id as query param of the fallback
        NSURLComponents *components = [[NSURLComponents alloc] initWithString:fallbackPage];

        NSMutableArray<NSURLQueryItem*> *queryItems = [components.queryItems mutableCopy];
        if (!queryItems)
        {
            queryItems = [NSMutableArray array];
        }

        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"device_id"
                                                          value:self.softLogoutCredentials.deviceId]];

        components.queryItems = queryItems;

        fallbackPage = components.URL.absoluteString;
    }

    [_authFallbackWebView openFallbackPage:fallbackPage success:^(MXLoginResponse *loginResponse) {
        
        MXCredentials *credentials = [[MXCredentials alloc] initWithLoginResponse:loginResponse andDefaultCredentials:self->mxRestClient.credentials];
        
        // TODO handle unrecognized certificate (if any) during registration through fallback webview.
        
        [self onSuccessfulLogin:credentials];
    }];
}

- (void)hideRegistrationFallbackView
{
    if (cancelFallbackBarButton)
    {
        NSMutableArray *rightBarButtonItems = [NSMutableArray arrayWithArray: self.navigationItem.rightBarButtonItems];
        [rightBarButtonItems removeObject:cancelFallbackBarButton];
        self.navigationItem.rightBarButtonItems = rightBarButtonItems;
    }
    
    [_authFallbackWebView stopLoading];
    _authenticationScrollView.hidden = NO;
    _authFallbackContentView.hidden = YES;
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([@"viewHeightConstraint.constant" isEqualToString:keyPath])
    {
        // Refresh the height of the auth inputs view container.
        CGFloat previousInputsContainerViewHeight = _authInputContainerViewHeightConstraint.constant;
        _authInputContainerViewHeightConstraint.constant = _authInputsView.viewHeightConstraint.constant;
        
        // Force to render the view
        [self.view layoutIfNeeded];
        
        // Refresh content view height by considering the updated height of inputs container
        _contentViewHeightConstraint.constant += (_authInputContainerViewHeightConstraint.constant - previousInputsContainerViewHeight);
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end
