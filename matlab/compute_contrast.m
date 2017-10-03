function [contrast, Jac] = compute_contrast(idx_to_mat, event_map, rotvec_pred, map, ...
    undist_pix_calibrated, grad_map)
% compute_contrast Measurement function for EKF correction step
%
% Compute the contrast of a set of events using current rotation and past
% rotations. Contrast is computed by difference of map intensities.
%
% Input:
% -idx_to_mat(N,1): event locations using indices into 1-D array of undistorted 2D coordinates
% -event_map: DVS pixel map of times and rotations of previous events
% -rotvec_pred(3,1): predicted state (rotation, before measurement update)
% -map: mosaic image, containing brightness information
% -undist_pix_calibrated(Npix,2): look-up-table of undistorted 2D coordinates
% -grad_map: (Optional) derivatives of the map, for "analytical" derivatives
%
% Output:
% -contrast(N,1): predicted contrast of current event(s) according to two
%            rotations and the map 
% -Jac(N,3): each row is the gradient of the contrast with respect to the
%            current state (rotation vector)

num_events_batch = numel(idx_to_mat);
[pano_height,pano_width] = size(map);

% 1. Get bearing vector of the event pixel
one_vec = ones(num_events_batch,1);
bearing_vec = [undist_pix_calibrated(idx_to_mat,:), one_vec]'; % 3xN
    
% 2a. Get map point corresponding to current event
Rot = expm( Cross2Matrix(rotvec_pred) );
rotated_bvec = Rot * bearing_vec;
if (nargout > 1)
    [pm,dpm_d3D] = project_EquirectangularProjection(rotated_bvec, pano_width, pano_height);
else
    pm = project_EquirectangularProjection(rotated_bvec, pano_width, pano_height);
end

% % Check analytical derivative against numerical one
% err = -ones(1,num_events_batch);
% for k = 1:num_events_batch
%     J_num = fdjac(rotated_bvec(:,k),'project_EquirectangularProjection',pano_width,pano_height);
%     err(k) = norm(dpm_d3D(:,:,k)-J_num,'fro')/norm(J_num,'fro');
% end
% norm(err)

% 2b. Get map point corresponding to previous event at same pixel
rotated_vec_prev = zeros(size(rotated_bvec));
for ii = 1:num_events_batch
    Rot_prev = event_map(idx_to_mat(ii)).rotation;
    rotated_vec_prev(:,ii) = Rot_prev * bearing_vec(:,ii);
end
pm_prev = project_EquirectangularProjection(rotated_vec_prev, pano_width, pano_height);

% 3. Subtract the intensities at both map points

% Nearest neighbor (no interpolation): Total failure for numerical gradient
% contrast = map(round(pm(2)),round(pm(1))) - map(round(pm_prev(2)),round(pm_prev(1)));

% Bilinear interpolation of intensities:
% M_cur = interp2(1:pano_width, 1:pano_height, map, pm(1,:), pm(2,:));
% M_prev = interp2(1:pano_width, 1:pano_height, map, pm_prev(1,:), pm_prev(2,:));
% contrast = M_cur(:) - M_prev(:);
%
% One function call instead of two is more efficient
M_ = interp2(1:pano_width, 1:pano_height, map, [pm(1,:),pm_prev(1,:)], [pm(2,:),pm_prev(2,:)]);
contrast = M_(1:num_events_batch) - M_(1+num_events_batch:end);
contrast = contrast(:);

% Compute Jacobians
if (nargout > 1) && (nargin > 5)
    % Derivative of the map wrt the 2D point pm
    M_deriv_x = interp2(1:pano_width, 1:pano_height, grad_map.x, pm(1,:), pm(2,:));
    M_deriv_y = interp2(1:pano_width, 1:pano_height, grad_map.y, pm(1,:), pm(2,:));
    % Derivative of the 2D point pm wrt rotated_bvec
    Jac = (M_deriv_x' * [1 1 1]) .* (squeeze(dpm_d3D(1,:,:))') + ...
        (M_deriv_y' * [1 1 1]) .* (squeeze(dpm_d3D(2,:,:))');

%     % This is the problematic part: derivatives of the map by finite
%     % differences do not agree with derivatives using bilinear interpolation
%     err = -ones(1,num_events_batch);
%     for ii = 1:num_events_batch
%         J_num = fdjac(rotated_bvec(:,ii),'test_deriv_contrast_wrt_rbvec',map, pano_width, pano_height);
%         err(ii) = norm(J_num - Jac(ii,:),'fro')/norm(J_num,'fro');
%     end
%     norm(err)

    % Derivative of rotated_bvec wrt rotvec_pred (the state)
    v = rotvec_pred;
    matrix_factor = (v*v' + (Rot'-eye(3))*Cross2Matrix(v)) / (norm(v).^2);
    
%     err = -ones(1,num_events_batch);
    for ii = 1:num_events_batch
        % Gallego and Yezzi, JMIV 2014. Formula for rotvec in [0,pi]
        drotated_bvec_dv = -Rot * Cross2Matrix(bearing_vec(:,ii)) * matrix_factor;
        
%         % Check analytical derivative
%         J_num = fdjac(rotvec_pred,'test_expm',bearing_vec(:,ii));
%         err(ii) = norm(J_num - drotated_bvec_dv,'fro')/norm(J_num,'fro');
        
        Jac(ii,:) = Jac(ii,:) * drotated_bvec_dv;
    end
%     norm(err)
end